with located as (
    select
        d.full_date as offense_date,
        p.cp as postal_cp,
        s.cp as socioeconomic_cp,
        s.median_household_income,
        s.income_top_coded
    from {{ ref('fact_crimes') }} c
    left join {{ ref('dim_date') }} d
        on d.date_key = c.offense_date_key
    left join {{ ref('dim_address') }} a
        on a.address_id = c.address_id
    left join {{ ref('dim_postal_codes') }} p
        on p.cp = a.cp
    left join {{ ref('dim_census_socioeconomic') }} s
        on s.cp = p.cp
),

source_stats as (
    select count(*) as original_crime_rows
    from {{ ref('fact_crimes') }}
),

coverage as (
    select
        coalesce(count_if(postal_cp is not null), 0)
            as valid_cp,

        coalesce(count_if(socioeconomic_cp is not null), 0)
            as socioeconomic_data,

        coalesce(count_if(
            socioeconomic_cp is not null
            and median_household_income >= 0
            and not income_top_coded
        ), 0) as uncensored_income,

        coalesce(count_if(
            postal_cp is not null
            and offense_date is not null
        ), 0) as postal_year,

        coalesce(count_if(
            postal_cp is not null
            and offense_date is not null
            and socioeconomic_cp is not null
        ), 0) as postal_year_socioeconomic

    from located
),

mart_stats as (
    select
        coalesce(count_if(
            m.block_address is not null
            and not a.is_location_redacted
        ), 0) as published_address,

        coalesce(count_if(m.point_geography is not null), 0)
            as mappable_point

    from {{ ref('mart_crimes_socioeconomic') }} m
    left join {{ ref('fact_crimes') }} c
        on c.crime_id = m.crime_id
    left join {{ ref('dim_address') }} a
        on a.address_id = c.address_id
)

select
    s.original_crime_rows,

    round(c.valid_cp * 100.0
        / nullif(s.original_crime_rows, 0), 2)
        as geographic_coverage_pct,

    round(c.socioeconomic_data * 100.0
        / nullif(s.original_crime_rows, 0), 2)
        as socioeconomic_coverage_pct,

    round(c.postal_year_socioeconomic * 100.0
        / nullif(c.postal_year, 0), 2)
        as postal_year_socioeconomic_coverage_pct,

    round(c.uncensored_income * 100.0
        / nullif(s.original_crime_rows, 0), 2)
        as uncensored_income_coverage_pct,

    round(m.published_address * 100.0
        / nullif(s.original_crime_rows, 0), 2)
        as published_address_coverage_pct,

    round(m.mappable_point * 100.0
        / nullif(s.original_crime_rows, 0), 2)
        as point_coverage_pct

from source_stats s
cross join coverage c
cross join mart_stats m