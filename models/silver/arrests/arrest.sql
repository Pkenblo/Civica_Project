{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='arrest_number',
    on_schema_change='fail'
) }}

with candidates as (
    select s.*,
           iff(is_location_redacted or has_missing_coordinates or has_invalid_coordinates,
               'A:' || s.arrest_number, null) as location_context
    from {{ ref('stg_arrests') }} s
    where s.arrest_number is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
),
resolved as (
    select s.arrest_number, s.ingested_at, s.arrest_occurred_date_time, s.arrest_reported_date_time,
           r.report_id, t.arrest_type_id, a.agent_key, p.subject_key, s.officer_age, s.subject_age_range,
           d.address_id, z.police_area_id, c.cad_profile_id, s.crisis_involved, s.complaint_involved,
           s.force_involved, s.terry_stop, s.demonstration, s.source_file, s.batch_id
    from candidates s
    left join {{ ref('reports') }} r on r.report_number = s.report_number
    left join {{ ref('arrest_types') }} t on t.description = s.arrest_type
    left join {{ ref('agents') }} a on a.officer_id = s.officer_id
    left join {{ ref('subject') }} p on p.sk_person = s.subject_id
    left join {{ ref('cad_profiles') }} c on equal_null(c.cad_clearance, s.cad_clearance)
        and equal_null(c.cad_initial_call_type, s.cad_initial_call_type) and equal_null(c.cad_priority, s.cad_priority)
    left join {{ ref('police_add') }} z on equal_null(z.precinct, s.precinct)
        and equal_null(z.sector, s.sector) and equal_null(z.beat, s.beat)
    left join {{ ref('full_address') }} d on equal_null(d.location_context, s.location_context)
        {% for col in ['block_address', 'latitude', 'longitude', 'neighborhood', 'reporting_area', 'census_block_2020',
                       'is_location_redacted', 'has_missing_coordinates', 'has_invalid_coordinates'] %}
        and equal_null(d.{{ col }}, s.{{ col }})
        {% endfor %}
)
select * exclude (source_file, batch_id)
from resolved
qualify row_number() over (
    partition by arrest_number
    order by ingested_at desc, source_file desc nulls last, batch_id desc nulls last,
             arrest_reported_date_time desc nulls last, arrest_occurred_date_time desc nulls last,
             to_json(array_construct(report_id, arrest_type_id, agent_key, subject_key, officer_age, subject_age_range,
                                     address_id, police_area_id, cad_profile_id, crisis_involved, complaint_involved,
                                     force_involved, terry_stop, demonstration)) desc
) = 1
