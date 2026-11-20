with observed_dates as (
    select offense_date::date as full_date from {{ ref('crimes') }}
    union all
    select report_date_time::date from {{ ref('reports') }}
    union all
    select arrest_occurred_date_time::date from {{ ref('arrest') }}
    union all
    select arrest_reported_date_time::date from {{ ref('arrest') }}
    union all
    select license_issue_date from {{ ref('licenses') }}
), bounds as (
    select min(full_date) as first_date, max(full_date) as last_date
    from observed_dates
), calendar as (
    select dateadd(day, offsets.value::integer, b.first_date) as full_date
    from bounds b,
        lateral flatten(input => array_generate_range(0, datediff(day, b.first_date, b.last_date) + 1)) offsets
)
select
    to_char(full_date, 'YYYYMMDD')::number(8, 0) as date_key,
    full_date,
    year(full_date) as year,
    quarter(full_date) as quarter_of_year,
    month(full_date) as month_of_year,
    monthname(full_date) as month_name,
    weekiso(full_date) as iso_week,
    yearofweekiso(full_date) as iso_week_year,
    day(full_date) as day_of_month,
    dayofweekiso(full_date) as day_of_week,
    dayname(full_date) as day_name,
    dayofweekiso(full_date) in (6, 7) as is_weekend,
    to_char(full_date, 'YYYY-MM') as year_month
from calendar
