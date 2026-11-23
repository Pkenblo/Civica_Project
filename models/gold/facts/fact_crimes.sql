{{ config(unique_key='crime_id', post_hook="{{ gold_prune(ref('crimes'), 'crime_id') }}") }}

with current_rows as (
select c.crime_id, 
       c.report_id, 
       c.offense_id,
       c.nibrs_key, 
       c.address_id, 
       c.police_area_id, 
       c.offense_category_id as offense_classification_id,
       c.offense_date as offense_date_time, 
       occurred.full_date as offense_date,
       occurred.date_key as offense_date_key,
       r.report_date_time, 
       reported.full_date as report_date, 
       reported.date_key as report_date_key,
       c.ingested_at, 1 as crime_count
from {{ ref('crimes') }} c
left join {{ ref('dim_report') }} r on r.report_id = c.report_id
left join {{ ref('dim_date') }} occurred on occurred.full_date = c.offense_date::date
left join {{ ref('dim_date') }} reported on reported.full_date = r.report_date_time::date
)
select c.* from current_rows c
{% if is_incremental() %}
where {{ after_max_ingested_at('c.ingested_at') }}
   -- La fecha del informe puede cambiar sin una nueva versión de este delito.
   or exists (
       select 1 from {{ this }} t
       where t.crime_id = c.crime_id
         and not equal_null(t.report_date_time, c.report_date_time)
   )
{% endif %}
