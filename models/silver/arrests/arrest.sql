{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='arrest_number',
    on_schema_change='fail'
) }}

with candidates as (
    select s.*
    from {{ ref('stg_arrests') }} s
    where s.arrest_number is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
),
resolved as (
    select
          s.arrest_number
        , s.ingested_at
        , s.arrest_occurred_date_time
        , s.arrest_registered_at
        , r.report_id
        , t.arrest_type_id
        , a.agent_key
        , p.subject_key
        , s.officer_age
        , s.subject_age_range
        , s.officer_squad as officer_squad_at_arrest
        , s.officer_title as officer_title_at_arrest
        , d.address_id
        , z.police_area_id
        , c.cad_profile_id
        , s.crisis_involved
        , s.complaint_involved
        , s.force_involved
        , s.terry_stop
        , s.demonstration
        , s.source_file
        , s.batch_id
    from candidates s
    left join {{ ref('reports') }} r on r.report_number = s.report_number
    left join {{ ref('arrest_types') }} t on t.description = s.arrest_type
    left join {{ ref('agents') }} a on a.officer_id = s.officer_id
    left join {{ ref('subject') }} p on p.sk_person = s.subject_id
    left join {{ ref('cad_profiles') }} c on equal_null(c.cad_clearance, s.cad_clearance)
        and equal_null(c.cad_initial_call_type, s.cad_initial_call_type) and equal_null(c.cad_priority, s.cad_priority)
    left join {{ ref('police_add') }} z on equal_null(z.precinct, s.precinct)
        and equal_null(z.sector, s.sector) and equal_null(z.beat, s.beat)
    left join {{ ref('full_address') }} d on d.address_id = {{ address_id('s') }}
)

select * exclude (
      source_file
    , batch_id
)
from resolved
qualify row_number() over (
    partition by arrest_number
    order by
          ingested_at desc
        , source_file desc nulls last
        , batch_id desc nulls last
        , arrest_registered_at desc nulls last
        , arrest_occurred_date_time desc nulls last
        , report_id desc nulls last
        , arrest_type_id desc nulls last
        , agent_key desc nulls last
        , subject_key desc nulls last
        , officer_age desc nulls last
        , subject_age_range desc nulls last
        , officer_squad_at_arrest desc nulls last
        , officer_title_at_arrest desc nulls last
        , address_id desc nulls last
        , police_area_id desc nulls last
        , cad_profile_id desc nulls last
        , crisis_involved desc nulls last
        , complaint_involved desc nulls last
        , force_involved desc nulls last
        , terry_stop desc nulls last
        , demonstration desc nulls last
) = 1
