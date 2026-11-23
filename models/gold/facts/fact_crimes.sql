{{ config(
    unique_key='crime_id',
    post_hook="{{ gold_prune(ref('crimes'), 'crime_id') }}"
) }}

with

-- Imports
crimes as (
    select *
    from {{ ref('crimes') }}
    {% if is_incremental() %}
    where {{ after_max_ingested_at('ingested_at') }}
    {% endif %}
)
, dim_report as (
    select *
    from {{ ref('dim_report') }}
)
, dim_date as (
    select *
    from {{ ref('dim_date') }}
)

-- CTEs
, current_rows as (
    select
          c.crime_id
        , c.report_id
        , c.offense_id
        , c.nibrs_key
        , c.address_id
        , c.police_area_id
        , c.offense_category_id as offense_classification_id
        , c.offense_date as offense_date_time
        , occurred.date_key as offense_date_key
        , reported.date_key as report_date_key
        , c.ingested_at
    from crimes c
    left join dim_report r
        on r.report_id = c.report_id
    left join dim_date occurred
        on occurred.full_date = c.offense_date::date
    left join dim_date reported
        on reported.full_date = r.report_date_time::date
)

-- Salida final
select *
from current_rows
