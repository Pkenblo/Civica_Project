{{ config(unique_key='crime_id') }}

with

-- Imports
fact_crimes as (
    select *
    from {{ ref('fact_crimes') }}
    {% if is_incremental() %}
    where coalesce({{ after_max_ingested_at('ingested_at') }}, true)
    {% endif %}
)
, dim_address as (
    select *
    from {{ ref('dim_address') }}
)
, dim_date as (
    select *
    from {{ ref('dim_date') }}
)
, dim_offense_classification as (
    select *
    from {{ ref('dim_offense_classification') }}
)
, dim_nibrs as (
    select *
    from {{ ref('dim_nibrs') }}
)
, dim_postal_codes as (
    select *
    from {{ ref('dim_postal_codes') }}
)
, dim_census_socioeconomic as (
    select *
    from {{ ref('dim_census_socioeconomic') }}
)

-- CTEs
, postal_context as (
    -- Mismos criterios ACS que en mart_arrest_socioeconomic.
    select
          p.cp
        , p.geography
        , p.boundary_version
        , s.zcta_name
        , s.cp is not null as has_socioeconomic_data
        , case
            when not s.income_top_coded then s.median_household_income
          end as median_household_income
        , s.income_margin_of_error
        , s.population
        , case
            when not s.home_value_top_coded then s.median_home_value
          end as median_home_value
        , case
            when not s.rent_top_coded then s.median_monthly_rent
          end as median_monthly_rent
        , s.income_top_coded
        , s.home_value_top_coded
        , s.rent_top_coded
        , case when s.income_top_coded then 250000 end as income_lower_bound
        , case when s.home_value_top_coded then 2000000 end as home_value_lower_bound
        , case when s.rent_top_coded then 3500 end as rent_lower_bound
    from dim_postal_codes p
    left join dim_census_socioeconomic s
        on s.cp = p.cp
)

, income_quintiles as (
    -- Una observación por zona, incluidas las zonas sin delitos.
    select
          cp
        , ntile(5) over (
            order by
                  median_household_income
                , cp
          ) as income_quintile
    from postal_context
    where geography is not null
        and median_household_income >= 0
)

, final as (
    select
          c.crime_id
        , d.full_date as offense_date
        , o.offense_category
        , o.offense_sub_category
        , n.offense_code as nibrs_code
        , n.offense_description as nibrs_description
        , case
            when n.offense_code in ('09A', '09B', '13A', '13B', '13C', '100')
                then 'Violencia y agresiones'
            when n.offense_code in ('120', '23A', '23B') then 'Robos y hurtos a personas'
            when n.offense_code in ('11A', '11B', '11C', '11D', '36A', '36B', '90H', '370')
                then 'Delitos sexuales'
            when n.offense_code in ('23C', '23D', '23E', '23H') then 'Hurtos generales'
            when n.offense_code in ('240', '23F', '23G') then 'Delitos contra vehículos'
            when n.offense_code in ('220', '90J') then 'Allanamientos y accesos ilegales'
            when n.offense_code in ('200', '290') then 'Vandalismo e incendios'
            when n.offense_code in (
                '90A', '510', '250', '26A', '26B', '26C', '26D', '26E', '26F', '26G', '270', '210', '280'
            ) then 'Fraudes y delitos económicos'
            when n.offense_code in ('35A', '35B') then 'Drogas'
            when n.offense_code = '520' then 'Armas'
            when n.offense_code in ('40A', '40B', '40C', '64A', '64B') then 'Prostitución y trata'
            when n.offense_code in ('90B', '90C', '90D', '90E', '90G', '39A', '39B', '39C')
                then 'Orden público, alcohol y juego'
            when n.offense_code in ('90F', '500') then 'Convivencia y órdenes de protección'
            when n.offense_code = '720' then 'Maltrato animal'
            when n.offense_code in ('09C', '90I', '90Z', '999') then 'Otros y registros especiales'
            else 'Sin clasificar'
          end as nibrs_category
        , a.block_address
        , a.neighborhood
        , a.cp
        , a.latitude
        , a.longitude
        , st_makepoint(a.longitude, a.latitude) as point_geography
        , p.cp is not null as has_postal_reference
        , p.geography
        , p.boundary_version
        , p.zcta_name
        , coalesce(p.has_socioeconomic_data, false) as has_socioeconomic_data
        , 2024 as acs_year
        , '2020–2024' as acs_period
        , p.median_household_income
        , p.income_margin_of_error
        , p.population
        , p.median_home_value
        , p.median_monthly_rent
        , p.income_top_coded
        , p.home_value_top_coded
        , p.rent_top_coded
        , p.income_lower_bound
        , p.home_value_lower_bound
        , p.rent_lower_bound
        , q.income_quintile
        , case q.income_quintile
            when 1 then 'muy bajo'
            when 2 then 'bajo'
            when 3 then 'medio'
            when 4 then 'alto'
            when 5 then 'muy alto'
          end as income_level
        , c.ingested_at
    from fact_crimes c
    join dim_address a
        on a.address_id = c.address_id
    left join dim_date d
        on d.date_key = c.offense_date_key
    left join dim_offense_classification o
        on o.offense_classification_id = c.offense_classification_id
    left join dim_nibrs n
        on n.nibrs_key = c.nibrs_key
    left join postal_context p
        on p.cp = a.cp
    left join income_quintiles q
        on q.cp = p.cp
    where a.block_address is not null
        and not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
        and a.latitude between -90 and 90
        and a.longitude between -180 and 180
)

select *
from final
