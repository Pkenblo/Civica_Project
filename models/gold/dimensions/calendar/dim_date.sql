
{{ config(
    tags=['static_model']
) }}

with calendar as (

    {{ dbt_date.get_date_dimension(
        '1900-01-01',
        '2101-01-01'
    ) }}

)

select
      to_char(date_day, 'YYYYMMDD')::number(8, 0) as date_key
    , date_day as full_date
    , year_number as year
    , quarter_of_year
    , month_of_year
    , month_name_short as month_name
    , iso_week_of_year as iso_week
    , yearofweekiso(date_day) as iso_week_year
    , day_of_month
    , day_of_week_iso as day_of_week
    , day_of_week_name_short as day_name
    , day_of_week_iso in (6, 7) as is_weekend
    , to_char(date_day, 'YYYY-MM') as year_month

from calendar
