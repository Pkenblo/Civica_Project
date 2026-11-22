with quintiles as (
    select p.cp, ntile(5) over (order by s.median_household_income, p.cp) as income_quintile
    from {{ ref('dim_postal_codes') }} p
    join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
    where p.geography is not null and s.median_household_income >= 0 and not s.income_top_coded
)

select m.crime_id
from {{ ref('mart_crimes_socioeconomic') }} m
left join {{ ref('dim_postal_codes') }} p on p.cp = m.cp
left join {{ ref('dim_census_socioeconomic') }} s on s.cp = p.cp
left join quintiles q on q.cp = m.cp
where st_aswkt(m.geography) is distinct from st_aswkt(p.geography)
   or m.has_postal_reference is distinct from (p.cp is not null)
   or m.boundary_version is distinct from p.boundary_version
   or m.zcta_name is distinct from s.zcta_name
   or m.has_socioeconomic_data is distinct from (s.cp is not null)
   or m.median_household_income is distinct from (case when not s.income_top_coded then s.median_household_income end)
   or m.income_margin_of_error is distinct from s.income_margin_of_error
   or m.population is distinct from s.population
   or m.median_home_value is distinct from (case when not s.home_value_top_coded then s.median_home_value end)
   or m.median_monthly_rent is distinct from (case when not s.rent_top_coded then s.median_monthly_rent end)
   or m.income_top_coded is distinct from s.income_top_coded
   or m.home_value_top_coded is distinct from s.home_value_top_coded
   or m.rent_top_coded is distinct from s.rent_top_coded
   or m.income_lower_bound is distinct from (case when s.income_top_coded then 250000 end)
   or m.home_value_lower_bound is distinct from (case when s.home_value_top_coded then 2000000 end)
   or m.rent_lower_bound is distinct from (case when s.rent_top_coded then 3500 end)
   or m.income_quintile is distinct from q.income_quintile
   or m.income_level is distinct from (
       case q.income_quintile when 1 then 'muy bajo' when 2 then 'bajo' when 3 then 'medio'
            when 4 then 'alto' when 5 then 'muy alto' end
   )
