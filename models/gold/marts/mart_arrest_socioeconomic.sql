with postal_context as (
    select
        p.cp
        ,p.geography
        ,p.boundary_version
        ,s.zcta_name
        ,s.cp is not null as has_socioeconomic_data
        -- Silver ya limpia los códigos negativos. Los límites no son estimaciones exactas.
        ,case when not s.income_top_coded then s.median_household_income end as median_household_income
        ,s.income_margin_of_error
        ,s.population
        ,case when not s.home_value_top_coded then s.median_home_value end as median_home_value
        ,case when not s.rent_top_coded then s.median_monthly_rent end as median_monthly_rent
        ,s.income_top_coded
        ,s.home_value_top_coded
        ,s.rent_top_coded
        ,case when s.income_top_coded then 250000 end as income_lower_bound
        ,case when s.home_value_top_coded then 2000000 end as home_value_lower_bound
        ,case when s.rent_top_coded then 3500 end as rent_lower_bound
    from {{ ref('dim_postal_codes') }} p
    left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
),

income_quintiles as (
    -- Una observación por zona, no una por detención ni por año.
    select
        cp
        ,ntile(5) over (
            order by
                median_household_income
                ,cp
        ) as income_quintile
    from postal_context
    where geography is not null and median_household_income >= 0
),

arrests as (
    select
        r.arrest_number
        ,r.arrest_occurred_date_time
        ,r.arrest_occurred_date
        ,year(r.arrest_occurred_date) as year
        ,r.address_id
        ,a.address_id is not null as has_address_data
        ,a.block_address
        ,a.latitude
        ,a.longitude
        ,a.neighborhood
        ,a.reporting_area
        ,a.census_block_2020
        ,a.cp
        ,a.cp_status
        ,a.is_location_redacted
        ,a.has_missing_coordinates
        ,a.has_invalid_coordinates
        ,case
            when not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
                and a.latitude between -90 and 90
                and a.longitude between -180 and 180
                then st_makepoint(a.longitude, a.latitude)
        end as point_geography
        ,p.cp is not null as has_postal_reference
        ,r.arrest_count
        ,case
            when p.cp is not null and r.arrest_occurred_date is not null
                then count(*) over (
                    partition by
                        a.cp
                        ,year(r.arrest_occurred_date)
                )
        end as postal_year_arrest_count
        ,p.geography
        ,p.boundary_version
        ,p.zcta_name
        ,coalesce(p.has_socioeconomic_data, false) as has_socioeconomic_data
        ,p.median_household_income
        ,p.income_margin_of_error
        ,p.population
        ,p.median_home_value
        ,p.median_monthly_rent
        ,p.income_top_coded
        ,p.home_value_top_coded
        ,p.rent_top_coded
        ,p.income_lower_bound
        ,p.home_value_lower_bound
        ,p.rent_lower_bound
        ,q.income_quintile
    from {{ ref('fact_arrests') }} r
    left join {{ ref('dim_address') }} a on a.address_id = r.address_id
    left join postal_context p on p.cp = a.cp
    left join income_quintiles q on q.cp = p.cp
)

select
    arrest_number
    ,arrest_occurred_date_time
    ,arrest_occurred_date
    ,year
    ,address_id
    ,has_address_data
    ,block_address
    ,latitude
    ,longitude
    ,point_geography
    ,neighborhood
    ,reporting_area
    ,census_block_2020
    ,cp
    ,cp_status
    ,is_location_redacted
    ,has_missing_coordinates
    ,has_invalid_coordinates
    ,has_postal_reference
    ,arrest_count
    ,postal_year_arrest_count
    ,postal_year_arrest_count * 1000.0 / nullif(population, 0) as postal_year_arrests_per_1000
    ,geography
    ,boundary_version
    ,zcta_name
    ,has_socioeconomic_data
    ,2024 as acs_year
    ,'2020–2024' as acs_period
    ,median_household_income
    ,income_margin_of_error
    ,population
    ,median_home_value
    ,median_monthly_rent
    ,income_top_coded
    ,home_value_top_coded
    ,rent_top_coded
    ,income_lower_bound
    ,home_value_lower_bound
    ,rent_lower_bound
    ,income_quintile
    ,case income_quintile
        when 1 then 'muy bajo'
        when 2 then 'bajo'
        when 3 then 'medio'
        when 4 then 'alto'
        when 5 then 'muy alto'
    end as income_level
from arrests
