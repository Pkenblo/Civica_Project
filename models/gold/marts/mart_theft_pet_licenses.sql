with common_years as (
    select year(offense_date) as year from {{ ref('fact_crimes') }} where offense_date is not null
    intersect
    select year(license_issue_date) as year from {{ ref('dim_licenses') }} where license_issue_date is not null
),

thefts as (
    select a.cp, year(c.offense_date) as year, count(*) as theft_count
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    where n.offense_code in ('120', '23A', '23B', '23H')
      and a.cp is not null and c.offense_date is not null
    group by a.cp, year(c.offense_date)
),

licenses as (
    select cp, year(license_issue_date) as year,
           sum(case when species = 'DOG' then 1 else 0 end) as dog_license_count,
           sum(case when species = 'CAT' then 1 else 0 end) as cat_license_count,
           sum(case when species = 'GOAT' then 1 else 0 end) as goat_license_count,
           sum(case when species = 'PIG' then 1 else 0 end) as pig_license_count,
           count(*) as pet_license_count
    from {{ ref('dim_licenses') }}
    where cp is not null and license_issue_date is not null and species in ('DOG', 'CAT', 'GOAT', 'PIG')
    group by cp, year(license_issue_date)
),

counts as (
    select p.cp, y.year, p.geography, p.boundary_version,
           coalesce(t.theft_count, 0) as theft_count,
           coalesce(l.dog_license_count, 0) as dog_license_count,
           coalesce(l.cat_license_count, 0) as cat_license_count,
           coalesce(l.goat_license_count, 0) as goat_license_count,
           coalesce(l.pig_license_count, 0) as pig_license_count,
           coalesce(l.pet_license_count, 0) as pet_license_count
    from {{ ref('dim_postal_codes') }} p
    cross join common_years y
    left join thefts t on t.cp = p.cp and t.year = y.year
    left join licenses l on l.cp = p.cp and l.year = y.year
)

select cp, year, theft_count, dog_license_count, cat_license_count, goat_license_count,
       pig_license_count, pet_license_count,
       dog_license_count / nullif(pet_license_count, 0) as dog_license_share,
       cat_license_count / nullif(pet_license_count, 0) as cat_license_share,
       goat_license_count / nullif(pet_license_count, 0) as goat_license_share,
       pig_license_count / nullif(pet_license_count, 0) as pig_license_share,
       geography, boundary_version
from counts
