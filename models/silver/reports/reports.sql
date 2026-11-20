{{ config(materialized='table') }}

with crime_reports as (
    select report_number, report_date_time
    from {{ ref('stg_crimes') }}
    where report_number is not null
    qualify row_number() over (
        partition by report_number
        order by ingested_at desc nulls last, source_file desc nulls last,
                 batch_id desc nulls last, report_date_time desc nulls last
    ) = 1
),
numbers as (
    select report_number from crime_reports
    union
    select report_number from {{ ref('stg_arrests') }} where report_number is not null
)
select md5(n.report_number) as report_id, n.report_number, c.report_date_time
from numbers n
left join crime_reports c using (report_number)
