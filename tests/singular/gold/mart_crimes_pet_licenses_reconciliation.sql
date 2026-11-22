with common_years as (
    select year(offense_date) as year from {{ ref('fact_crimes') }} where offense_date is not null
    intersect
    select year(license_issue_date) as year from {{ ref('dim_licenses') }} where license_issue_date is not null
),
vehicles as (
    select a.cp, year(c.offense_date) as year, count(*) as n
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    where n.offense_code = '240' and a.cp is not null and c.offense_date is not null
    group by a.cp, year(c.offense_date)
),
thefts as (
    select a.cp, year(c.offense_date) as year, count(*) as n
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    where n.offense_code in ('120','23A','23B','23H') and a.cp is not null and c.offense_date is not null
    group by a.cp, year(c.offense_date)
),
shootings as (
    select a.cp, year(c.offense_date) as year, count(*) as n
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    left join (select distinct crime_id from {{ ref('bridge_crime_shooting_types') }}) s on s.crime_id = c.crime_id
    where (s.crime_id is not null or n.offense_code in ('09A','09B','09C'))
      and a.cp is not null and c.offense_date is not null
    group by a.cp, year(c.offense_date)
),
licenses as (
    select cp, year(license_issue_date) as year,
           sum(case when species = 'DOG' then 1 else 0 end) as dogs,
           sum(case when species = 'CAT' then 1 else 0 end) as cats,
           sum(case when species = 'GOAT' then 1 else 0 end) as goats,
           sum(case when species = 'PIG' then 1 else 0 end) as pigs
    from {{ ref('dim_licenses') }}
    where cp is not null and license_issue_date is not null and species in ('DOG','CAT','GOAT','PIG')
    group by cp, year(license_issue_date)
),
history as (
    select p.cp, y.year, coalesce(sum(l.dogs),0) as dogs, coalesce(sum(l.cats),0) as cats,
           coalesce(sum(l.goats),0) as goats, coalesce(sum(l.pigs),0) as pigs
    from {{ ref('dim_postal_codes') }} p cross join common_years y
    left join licenses l on l.cp=p.cp and l.year<=y.year
    group by p.cp,y.year
),
expected as (
    select p.cp, y.year, coalesce(v.n,0) as vehicles, coalesce(t.n,0) as thefts, coalesce(s.n,0) as shootings,
           coalesce(l.dogs,0) as dogs, coalesce(l.cats,0) as cats,
           coalesce(l.goats,0) as goats, coalesce(l.pigs,0) as pigs,
           h.dogs as cumulative_dogs, h.cats as cumulative_cats,
           h.goats as cumulative_goats, h.pigs as cumulative_pigs
    from {{ ref('dim_postal_codes') }} p cross join common_years y
    left join vehicles v on v.cp=p.cp and v.year=y.year
    left join thefts t on t.cp=p.cp and t.year=y.year
    left join shootings s on s.cp=p.cp and s.year=y.year
    left join licenses l on l.cp=p.cp and l.year=y.year
    join history h on h.cp=p.cp and h.year=y.year
)
select coalesce(e.cp,m.cp) as cp, coalesce(e.year,m.year) as year
from expected e full outer join {{ ref('mart_crimes_pet_licenses') }} m on e.cp=m.cp and e.year=m.year
where e.cp is null or m.cp is null
   or m.vehicle_theft_count <> e.vehicles or m.theft_count <> e.thefts
   or m.shooting_or_homicide_count <> e.shootings
   or m.dog_license_count <> e.dogs or m.cat_license_count <> e.cats
   or m.goat_license_count <> e.goats or m.pig_license_count <> e.pigs
   or m.pet_license_count <> e.dogs + e.cats + e.goats + e.pigs
   or m.cumulative_dog_license_count <> e.cumulative_dogs
   or m.cumulative_cat_license_count <> e.cumulative_cats
   or m.cumulative_goat_license_count <> e.cumulative_goats
   or m.cumulative_pig_license_count <> e.cumulative_pigs
