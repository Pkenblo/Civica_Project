with common_years as (
    select year(offense_date) as year from {{ ref('fact_crimes') }} where offense_date is not null
    intersect
    select year(license_issue_date) as year from {{ ref('dim_licenses') }} where license_issue_date is not null
),

shooting_crimes as (
    select distinct crime_id from {{ ref('bridge_crime_shooting_types') }}
),

serious_crimes as (
    select a.cp, year(c.offense_date) as year, count(*) as shooting_or_homicide_count
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join shooting_crimes s on s.crime_id = c.crime_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    where (s.crime_id is not null or n.offense_code in ('09A', '09B', '09C'))
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
           coalesce(c.shooting_or_homicide_count, 0) as shooting_or_homicide_count,
           coalesce(l.dog_license_count, 0) as dog_license_count,
           coalesce(l.cat_license_count, 0) as cat_license_count,
           coalesce(l.goat_license_count, 0) as goat_license_count,
           coalesce(l.pig_license_count, 0) as pig_license_count,
           coalesce(l.pet_license_count, 0) as pet_license_count
    from {{ ref('dim_postal_codes') }} p
    cross join common_years y
    left join serious_crimes c on c.cp = p.cp and c.year = y.year
    left join licenses l on l.cp = p.cp and l.year = y.year
)

select cp, year, shooting_or_homicide_count, dog_license_count, cat_license_count, goat_license_count,
       pig_license_count, pet_license_count,
       dog_license_count / nullif(pet_license_count, 0) as dog_license_share,
       cat_license_count / nullif(pet_license_count, 0) as cat_license_share,
       goat_license_count / nullif(pet_license_count, 0) as goat_license_share,
       pig_license_count / nullif(pet_license_count, 0) as pig_license_share,
       geography, boundary_version
from counts
