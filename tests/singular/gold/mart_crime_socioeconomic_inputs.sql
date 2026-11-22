-- depends_on: {{ ref('mart_crime_socioeconomic') }}
-- Solo contratos necesarios para que los JOIN del nuevo mart sean muchos-a-uno.
with issues as (
    select 'fact_crimes.crime_id' as input_key, crime_id as key_value
    from {{ ref('fact_crimes') }}
    group by crime_id
    having crime_id is null or count(*) <> 1

    union all
    select 'fact_crimes.crime_count', crime_id
    from {{ ref('fact_crimes') }} where crime_count is distinct from 1

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
    select 'dim_offense_classification.offense_classification_id', offense_classification_id
    from {{ ref('dim_offense_classification') }}
    group by offense_classification_id
    having offense_classification_id is null or count(*) <> 1

    union all
    select 'fact_crimes.offense_classification_id', c.crime_id
    from {{ ref('fact_crimes') }} c
    left join {{ ref('dim_offense_classification') }} o
        on o.offense_classification_id = c.offense_classification_id
    where c.offense_classification_id is not null and o.offense_classification_id is null

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
