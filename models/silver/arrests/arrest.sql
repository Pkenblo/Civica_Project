-- Estado consolidado: una fila por arrest_number; las infracciones siguen en arrest_offenses.
-- Incremental estándar MERGE, sin estrategias personalizadas ni cursor por batch_id.
-- Compara versiones normalizadas y su ingesta real, no la fecha del arresto.
-- Solo consolida el histórico de los IDs nuevos/cambiados. RAW debe conservar ese histórico.
-- Los conflictos priorizan completitud, ingesta y fingerprint; los nulos nunca ganan a valores.
-- La protección de identidades y REDACTED prevalece sobre completar atributos sensibles.
-- depends_on: {{ ref('full_address') }}

{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='arrest_number',
    tmp_relation_type='table',
    on_schema_change='fail',
    database=env_var('DBT_SILVER'),
    schema='SILVER'
) }}

with incoming_versions as (

    {{ arrest_scored_versions(ref('stg_arrests')) }}

),

distinct_versions as (

    select distinct
          arrest_number
        , ingested_at
        , sha2(to_json(array_construct(
              _row_fingerprint, convert_timezone('UTC', ingested_at)::timestamp_ntz
          )), 256) as version_fingerprint
    from incoming_versions

),

source_state as (

    select
          arrest_number
        , max(ingested_at) as last_ingested_at
        , count(*) as source_version_count
        , sha2(to_json(array_agg(version_fingerprint)
              within group (order by version_fingerprint)), 256) as source_signature
    from distinct_versions
    group by arrest_number

),

affected_ids as (

    select incoming.arrest_number
    from source_state as incoming
    {% if is_incremental() %}
    left join {{ this }} as previous
        on incoming.arrest_number = previous.arrest_number
    where previous.arrest_number is null
        or not equal_null(incoming.last_ingested_at, previous.last_ingested_at)
        or not equal_null(incoming.source_signature, previous.source_signature)
        or not equal_null(incoming.source_version_count, previous.source_version_count)
    {% endif %}

),

history as (

    select staging.* exclude (_completeness_score, _row_fingerprint)
    from incoming_versions as staging
    inner join affected_ids on staging.arrest_number = affected_ids.arrest_number

),

consolidated as (

    {{ consolidate_arrests('history') }}

),

preserved_attributes as (

    -- Completa atributos del destino ANTES de recalcular las claves de sus catálogos.
    -- Los JSON null se convierten a SQL NULL; false y 0 conservan su significado.
    select consolidated.*
    {% if is_incremental() %}
    replace (
        {% for column in arrest_business_columns() %}
        {% set kind = 'varchar' %}
        {% if column in ['arrest_occurred_date_time', 'arrest_reported_date_time'] %}
            {% set kind = 'timestamp_ntz' %}
        {% elif column in ['officer_age', 'cad_priority'] %}
            {% set kind = 'number(38, 0)' %}
        {% elif column in ['latitude', 'longitude'] %}
            {% set kind = 'number(18, 5)' %}
        {% elif column in ['crisis_involved', 'complaint_involved', 'force_involved', 'terry_stop', 'demonstration'] %}
            {% set kind = 'boolean' %}
        {% endif %}
        {% set old = "nullif(get(previous.consolidation_choices, '" ~ column ~ "'), parse_json('null'))::" ~ kind %}
        {% if column in ['arrest_occurred_date_time', 'arrest_reported_date_time', 'cad_clearance', 'cad_initial_call_type', 'cad_priority', 'crisis_involved', 'complaint_involved', 'force_involved', 'terry_stop', 'demonstration'] %}
            {% set old = 'coalesce(' ~ old ~ ', previous.' ~ column ~ ')' %}
        {% endif %}
        case
            {% if column in ['officer_age', 'officer_gender', 'officer_race', 'officer_squad', 'officer_title'] %}
            when consolidated.officer_id is not null
                and not equal_null(consolidated.officer_id,
                    nullif(previous.consolidation_choices:officer_id, parse_json('null'))::varchar)
                then consolidated.{{ column }}
            {% elif column in ['subject_age_range', 'subject_gender', 'subject_race'] %}
            when consolidated.subject_id is not null
                and not equal_null(consolidated.subject_id,
                    nullif(previous.consolidation_choices:subject_id, parse_json('null'))::varchar)
                then consolidated.{{ column }}
            {% elif column in ['block_address', 'latitude', 'longitude', 'neighborhood', 'reporting_area', 'census_block_2020'] %}
            when consolidated.is_location_redacted
                or consolidated.last_redacted_at >= previous.last_ingested_at
                then consolidated.{{ column }}
            {% endif %}
            when consolidated.{{ column }} is not null then consolidated.{{ column }}
            else {{ old }}
        end as {{ column }}{{ ',' if not loop.last }}
        {% endfor %}
    )
    {% endif %}
    from consolidated
    {% if is_incremental() %}
    left join {{ this }} as previous on consolidated.arrest_number = previous.arrest_number
    {% endif %}

),

ready as (

    select preserved_attributes.* replace (
        object_construct_keep_null(
            {% for column in arrest_business_columns() %}
            '{{ column }}', {{ column }}{{ ',' if not loop.last }}
            {% endfor %}
        ) as consolidation_choices,
        (latitude is null or longitude is null) as has_missing_coordinates,
        (has_invalid_coordinates and (latitude is null or longitude is null)) as has_invalid_coordinates
    )
    from preserved_attributes

),

observations as (

    select distinct
          arrest_number
        , last_ingested_at
        , max_completeness_score
        , consolidation_conflicts
        , consolidation_choices
        , arrest_occurred_date_time
        , arrest_reported_date_time
        , report_number
        , arrest_type
        , officer_id, officer_age, officer_gender, officer_race, officer_squad, officer_title
        , subject_id, subject_age_range, subject_gender, subject_race
        , precinct, sector, beat
        , block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
        , cad_clearance
        , cad_initial_call_type
        , cad_priority
        , crisis_involved
        , complaint_involved
        , force_involved
        , terry_stop
        , demonstration
        , case
            when is_location_redacted or has_missing_coordinates or has_invalid_coordinates
                then 'arrests:' || arrest_number
            else null
          end as location_context
    from ready

),

keyed as (

    -- Contrato compartido con full_address.sql, idéntico al utilizado en crimes.sql.
    select
          observations.*
        , {{ dbt_utils.generate_surrogate_key([
              'block_address', 'latitude', 'longitude', 'neighborhood',
              'reporting_area', 'census_block_2020', 'is_location_redacted',
              'has_missing_coordinates', 'has_invalid_coordinates', 'location_context'
          ]) }} as address_id
    from observations

),

candidate as (

select distinct
      arrests.arrest_number
    , arrests.last_ingested_at
    , state.source_version_count
    , state.source_signature
    , arrests.max_completeness_score
    , arrests.consolidation_conflicts
    , arrests.consolidation_choices
    , arrests.arrest_occurred_date_time
    , arrests.arrest_reported_date_time
    , reports.report_id
    , types.arrest_type_id
    , case when arrests.officer_id is not null then coalesce(
          agents.agent_key,
          {{ dbt_utils.generate_surrogate_key([
              'arrests.officer_id', 'arrests.officer_age', 'arrests.officer_gender',
              'arrests.officer_race', 'arrests.officer_squad', 'arrests.officer_title'
          ]) }}
      ) end as agent_key
    , case when arrests.subject_id is not null then coalesce(
          people.subject_key,
          {{ dbt_utils.generate_surrogate_key([
              'arrests.subject_id', 'arrests.subject_age_range',
              'arrests.subject_gender', 'arrests.subject_race'
          ]) }}
      ) end as subject_key
    , arrests.address_id
    , police.police_area_id
    , arrests.cad_clearance
    , arrests.cad_initial_call_type
    , arrests.cad_priority
    , arrests.crisis_involved
    , arrests.complaint_involved
    , arrests.force_involved
    , arrests.terry_stop
    , arrests.demonstration
from keyed as arrests
inner join source_state as state on arrests.arrest_number = state.arrest_number
left join {{ ref('reports') }} as reports
    on arrests.report_number = reports.report_number
left join {{ ref('arrest_types') }} as types
    on arrests.arrest_type = types.description
left join {{ ref('agents') }} as agents
    on arrests.officer_id = agents.officer_id
    and equal_null(arrests.officer_age, agents.officer_age)
    and equal_null(arrests.officer_gender, agents.officer_gender)
    and equal_null(arrests.officer_race, agents.officer_race)
    and equal_null(arrests.officer_squad, agents.squad_description)
    and equal_null(arrests.officer_title, agents.officer_title)
left join {{ ref('subject') }} as people
    on arrests.subject_id = people.sk_person
    and equal_null(arrests.subject_age_range, people.subject_age_range)
    and equal_null(arrests.subject_gender, people.subject_gender)
    and equal_null(arrests.subject_race, people.subject_race)
left join {{ ref('police_add') }} as police
    on equal_null(arrests.precinct, police.precinct)
    and equal_null(arrests.sector, police.sector)
    and equal_null(arrests.beat, police.beat)

)

-- Protección explícita del destino: no confiar únicamente en unique_key.
-- Primero se consolidan atributos; después se preserva cada columna nullable ya publicada.
select
      candidate.arrest_number
    , candidate.last_ingested_at
    , candidate.source_version_count
    , candidate.source_signature
    , candidate.max_completeness_score
    , candidate.consolidation_conflicts
    , candidate.consolidation_choices
    {% for column in [
        'arrest_occurred_date_time', 'arrest_reported_date_time', 'report_id', 'arrest_type_id',
        'agent_key', 'subject_key', 'address_id', 'police_area_id', 'cad_clearance',
        'cad_initial_call_type', 'cad_priority', 'crisis_involved', 'complaint_involved',
        'force_involved', 'terry_stop', 'demonstration'
    ] %}
    , {% if is_incremental() %}coalesce(candidate.{{ column }}, previous.{{ column }}){% else %}candidate.{{ column }}{% endif %} as {{ column }}
    {% endfor %}
from candidate
{% if is_incremental() %}
left join {{ this }} as previous on candidate.arrest_number = previous.arrest_number
{% endif %}
