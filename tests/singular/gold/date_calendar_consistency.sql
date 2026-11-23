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
), expected as (
    select min(full_date) as first_date, max(full_date) as last_date
    from observed_dates
), actual as (
    select min(full_date) as first_date, max(full_date) as last_date, count(*) as date_count
    from {{ ref('dim_date') }}
)
select 'calendar_bounds_or_gaps' as issue
from expected e cross join actual a
where a.first_date is distinct from e.first_date
   or a.last_date is distinct from e.last_date
   or a.date_count <> coalesce(datediff(day, e.first_date, e.last_date) + 1, 0)
union all
select 'calendar_attributes' as issue
from {{ ref('dim_date') }}
where date_key is distinct from to_char(full_date, 'YYYYMMDD')::number(8, 0)
   or year is distinct from year(full_date)
   or quarter_of_year is distinct from quarter(full_date)
   or month_of_year is distinct from month(full_date)
   or month_name is distinct from monthname(full_date)
   or iso_week is distinct from weekiso(full_date)
   or iso_week_year is distinct from yearofweekiso(full_date)
   or day_of_month is distinct from day(full_date)
   or day_of_week is distinct from dayofweekiso(full_date)
   or day_name is distinct from dayname(full_date)
   or is_weekend is distinct from (dayofweekiso(full_date) in (6, 7))
   or year_month is distinct from to_char(full_date, 'YYYY-MM')
