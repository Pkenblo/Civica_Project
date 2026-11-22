-- depends_on: {{ ref('mart_arrest_socioeconomic') }}
-- Solo contratos necesarios para que los JOIN del nuevo mart sean muchos-a-uno.
with issues as (
    select 'fact_arrests.arrest_number' as input_key, arrest_number as key_value
    from {{ ref('fact_arrests') }}
    group by arrest_number
    having arrest_number is null or count(*) <> 1

    union all
    select 'fact_arrests.arrest_count', arrest_number
    from {{ ref('fact_arrests') }} where arrest_count is distinct from 1

    union all
    select 'dim_address.address_id', address_id
    from {{ ref('dim_address') }}
    group by address_id
    having address_id is null or count(*) <> 1

    union all
    select 'dim_postal_codes.cp', cp
    from {{ ref('dim_postal_codes') }}
    group by cp
    having cp is null or count(*) <> 1

    union all
    select 'dim_census_socioeconomic.cp', cp
    from {{ ref('dim_census_socioeconomic') }}
    group by cp
    having cp is null or count(*) <> 1

    union all
    select 'dim_address.cp_status', address_id
    from {{ ref('dim_address') }}
    where cp is not null and cp_status is distinct from 'matched'

    union all
    select 'dim_census_socioeconomic.negative_value', cp
    from {{ ref('dim_census_socioeconomic') }}
    where median_household_income < 0 or income_margin_of_error < 0 or population < 0
       or median_home_value < 0 or median_monthly_rent < 0

    union all
    select 'dim_census_socioeconomic.top_coded_flags', cp
    from {{ ref('dim_census_socioeconomic') }}
    where income_top_coded is distinct from coalesce(median_household_income = 250001, false)
       or home_value_top_coded is distinct from coalesce(median_home_value = 2000001, false)
       or rent_top_coded is distinct from coalesce(median_monthly_rent = 3501, false)
)
select * from issues
