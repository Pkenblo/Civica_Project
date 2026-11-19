-- Consolida por columna: completitud de la versión, ingesta UTC y fingerprint determinista.
-- No cuenta metadatos ni infracciones en la completitud. Expone los valores contradictorios.
-- Mantiene separadas las identidades y no reconstruye ubicaciones ocultadas.

{% macro consolidate_arrests(relation) %}

{% set scalar_columns = [
    'arrest_occurred_date_time', 'arrest_reported_date_time', 'report_number', 'arrest_type',
    'precinct', 'sector', 'beat', 'cad_clearance', 'cad_initial_call_type', 'cad_priority',
    'crisis_involved', 'complaint_involved', 'force_involved', 'terry_stop', 'demonstration'
] %}
{% set officer_columns = ['officer_age', 'officer_gender', 'officer_race', 'officer_squad', 'officer_title'] %}
{% set subject_columns = ['subject_age_range', 'subject_gender', 'subject_race'] %}
{% set location_columns = ['block_address', 'latitude', 'longitude', 'neighborhood', 'reporting_area', 'census_block_2020'] %}
{% set priority = '_completeness_score desc, ingested_at desc, _row_fingerprint desc' %}

with scored as (

    {{ arrest_scored_versions(relation) }}

),

identities as (

    select
          scored.*
        , first_value(officer_id) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as selected_officer_id
        , first_value(subject_id) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as selected_subject_id
        , max(case when is_location_redacted then ingested_at end)
              over (partition by arrest_number) as last_redacted_at
    from scored

),

combined as (

    select distinct
          arrest_number
        , max(ingested_at) over (partition by arrest_number) as last_ingested_at
        , max(last_redacted_at) over (partition by arrest_number) as last_redacted_at
        , max(_completeness_score) over (partition by arrest_number) as max_completeness_score
        , object_construct(
            {% for column in arrest_business_columns() %}
            {% set comparable = column %}
            {% if column in location_columns %}
                {% set comparable = 'case when last_redacted_at is null or ingested_at > last_redacted_at then ' ~ column ~ ' end' %}
            {% elif column in officer_columns %}
                {% set comparable = 'case when officer_id = selected_officer_id then ' ~ column ~ ' end' %}
            {% elif column in subject_columns %}
                {% set comparable = 'case when subject_id = selected_subject_id then ' ~ column ~ ' end' %}
            {% endif %}
            '{{ column }}', case when count(distinct {{ comparable }}) over (partition by arrest_number) > 1
                then array_unique_agg(to_variant({{ comparable }})) over (partition by arrest_number) end
            {{ ',' if not loop.last }}
            {% endfor %}
          ) as consolidation_conflicts
        {% for column in scalar_columns %}
        , first_value({{ column }}) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as {{ column }}
        {% endfor %}
        , selected_officer_id as officer_id
        {% for column in officer_columns %}
        , first_value(case when officer_id = selected_officer_id then {{ column }} end) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as {{ column }}
        {% endfor %}
        , selected_subject_id as subject_id
        {% for column in subject_columns %}
        , first_value(case when subject_id = selected_subject_id then {{ column }} end) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as {{ column }}
        {% endfor %}
        {% for column in location_columns %}
        , first_value(case
              when not is_location_redacted
                  and (last_redacted_at is null or ingested_at > last_redacted_at)
                  {% if column in ['latitude', 'longitude'] %}
                  and not has_invalid_coordinates
                  {% endif %}
                  then {{ column }}
          end) ignore nulls over (
              partition by arrest_number order by {{ priority }}
              rows between unbounded preceding and unbounded following
          ) as {{ column }}
        {% endfor %}
        , first_value(is_location_redacted) over (
              partition by arrest_number order by ingested_at desc, _row_fingerprint desc
              rows between unbounded preceding and unbounded following
          ) as is_location_redacted
        , first_value(has_invalid_coordinates) over (
              partition by arrest_number order by ingested_at desc, _row_fingerprint desc
              rows between unbounded preceding and unbounded following
          ) as latest_has_invalid_coordinates
    from identities

)

select
      combined.* exclude (latest_has_invalid_coordinates)
    , object_construct_keep_null(
        {% for column in arrest_business_columns() %}
        '{{ column }}', {{ column }}{{ ',' if not loop.last }}
        {% endfor %}
      ) as consolidation_choices
    , (latitude is null or longitude is null) as has_missing_coordinates
    , (coalesce(latest_has_invalid_coordinates, false)
        and (latitude is null or longitude is null)) as has_invalid_coordinates
from combined

{% endmacro %}
