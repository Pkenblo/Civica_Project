{{ config(
    unique_key='arrest_number',
    post_hook="{{ gold_prune(ref('arrest'), 'arrest_number') }}"
) }}

with

-- Imports
arrest as (
    select *
    from {{ ref('arrest') }}
    {% if is_incremental() %}
    where {{ after_max_ingested_at('ingested_at') }}
    {% endif %}
)
,dim_date as (
    select *
    from {{ ref('dim_date') }}
)

-- CTEs
,current_rows as (
    select
         a.arrest_number
        ,a.report_id
        ,a.address_id
        ,a.police_area_id
        ,a.arrest_type_id
        ,a.agent_key
        ,a.subject_key
        ,a.cad_profile_id
        ,a.arrest_occurred_date_time
        ,occurred.date_key as arrest_occurred_date_key
        ,a.arrest_registered_at
        ,reported.date_key as arrest_reported_date_key
        ,a.officer_age
        ,a.subject_age_range
        ,a.officer_squad_at_arrest
        ,a.officer_title_at_arrest
        ,a.crisis_involved
        ,a.complaint_involved
        ,a.force_involved
        ,a.terry_stop
        ,a.demonstration
        ,a.ingested_at
    from arrest a
    left join dim_date occurred
        on occurred.full_date = a.arrest_occurred_date_time::date
    left join dim_date reported
        on reported.full_date = a.arrest_registered_at::date
)

-- Salida final
select *
from current_rows
