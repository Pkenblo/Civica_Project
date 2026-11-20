{{ config(unique_key='arrest_number', post_hook="{{ gold_prune_missing_keys(ref('arrest'), 'arrest_number') }}") }}

with current_rows as (
select a.arrest_number, a.report_id, a.address_id, a.police_area_id,
       a.arrest_type_id, a.agent_key, a.subject_key, a.cad_profile_id,
       a.arrest_occurred_date_time, occurred.full_date as arrest_occurred_date,
       occurred.date_key as arrest_occurred_date_key,
       a.arrest_reported_date_time, reported.full_date as arrest_reported_date,
       reported.date_key as arrest_reported_date_key,
       a.officer_age, a.subject_age_range, a.crisis_involved, a.complaint_involved,
       a.force_involved, a.terry_stop, a.demonstration, a.ingested_at, 1 as arrest_count
from {{ ref('arrest') }} a
left join {{ ref('dim_date') }} occurred on occurred.full_date = a.arrest_occurred_date_time::date
left join {{ ref('dim_date') }} reported on reported.full_date = a.arrest_reported_date_time::date
)
{{ gold_changed_rows() }}
