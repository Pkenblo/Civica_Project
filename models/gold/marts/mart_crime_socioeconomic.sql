with crime_years as (
    select distinct year(offense_date) as year
    from {{ ref('fact_crimes') }}
    where offense_date is not null
),

classifications as (
    select offense_classification_id, offense_category_id, offense_subcategory_id,
           offense_category, offense_sub_category
    from {{ ref('dim_offense_classification') }}

    union all

    -- Una clasificación ausente no debe excluir el delito ni inventar una clave Gold.
    select null::varchar, null::varchar, null::varchar, null::varchar, null::varchar
),

crime_counts as (
    select a.cp, year(c.offense_date) as year, c.offense_classification_id,
           count(*) as crime_count
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    where a.cp is not null and c.offense_date is not null
    group by a.cp, year(c.offense_date), c.offense_classification_id
),

postal_context as (
    select p.cp, p.geography, p.boundary_version, s.zcta_name,
           s.cp is not null as has_socioeconomic_data,
           -- Silver ya limpia los códigos negativos. Los límites no son estimaciones exactas.
           case when not s.income_top_coded then s.median_household_income end as median_household_income,
           s.income_margin_of_error, s.population,
           case when not s.home_value_top_coded then s.median_home_value end as median_home_value,
           case when not s.rent_top_coded then s.median_monthly_rent end as median_monthly_rent,
           s.income_top_coded, s.home_value_top_coded, s.rent_top_coded,
           case when s.income_top_coded then 250000 end as income_lower_bound,
           case when s.home_value_top_coded then 2000000 end as home_value_lower_bound,
           case when s.rent_top_coded then 3500 end as rent_lower_bound
    from {{ ref('dim_postal_codes') }} p
    left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
),

income_quintiles as (
    -- Una observación por zona, antes de expandir por año o clasificación.
    select cp, ntile(5) over (order by median_household_income, cp) as income_quintile
    from postal_context
    where geography is not null and median_household_income >= 0
),

counts as (
    select p.cp, y.year, o.offense_classification_id, o.offense_category_id,
           o.offense_subcategory_id, o.offense_category, o.offense_sub_category,
           coalesce(c.crime_count, 0) as crime_count,
           sum(coalesce(c.crime_count, 0)) over (partition by p.cp, y.year) as postal_year_crime_count,
           p.geography, p.boundary_version, p.zcta_name, p.has_socioeconomic_data,
           p.median_household_income, p.income_margin_of_error, p.population,
           p.median_home_value, p.median_monthly_rent,
           p.income_top_coded, p.home_value_top_coded, p.rent_top_coded,
           p.income_lower_bound, p.home_value_lower_bound, p.rent_lower_bound,
           q.income_quintile
    from postal_context p
    cross join crime_years y
    cross join classifications o
    left join crime_counts c on c.cp = p.cp and c.year = y.year
        and equal_null(c.offense_classification_id, o.offense_classification_id)
    left join income_quintiles q on q.cp = p.cp
)

select cp, year, offense_classification_id, offense_category_id, offense_subcategory_id,
       offense_category, offense_sub_category, crime_count, postal_year_crime_count,
       crime_count * 1000.0 / nullif(population, 0) as crimes_per_1000,
       postal_year_crime_count * 1000.0 / nullif(population, 0) as postal_year_crimes_per_1000,
       crime_count * 100.0 / nullif(postal_year_crime_count, 0) as crime_share_pct,
       geography, boundary_version, zcta_name, has_socioeconomic_data,
       2024 as acs_year, '2020–2024' as acs_period,
       median_household_income, income_margin_of_error, population, median_home_value, median_monthly_rent,
       income_top_coded, home_value_top_coded, rent_top_coded,
       income_lower_bound, home_value_lower_bound, rent_lower_bound, income_quintile,
       case income_quintile
           when 1 then 'muy bajo'
           when 2 then 'bajo'
           when 3 then 'medio'
           when 4 then 'alto'
           when 5 then 'muy alto'
       end as income_level
from counts
