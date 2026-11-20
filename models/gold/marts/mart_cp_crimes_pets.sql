{{ config(materialized='table') }}

with crimes_by_cp_year as (
    select a.cp, d.year, sum(c.crime_count) as total_crimes
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    join {{ ref('dim_date') }} d on d.date_key = c.offense_date_key
    where a.cp is not null
    group by a.cp, d.year
), licenses_by_cp_year as (
    select l.cp, d.year, count(*) as total_licenses_issued,
           sum(iff(l.species_group = 'dog', 1, 0)) as dog_licenses_issued,
           sum(iff(l.species_group = 'cat', 1, 0)) as cat_licenses_issued,
           sum(iff(l.species_group = 'other', 1, 0)) as other_species_licenses_issued,
           sum(iff(l.species_group = 'unknown', 1, 0)) as unknown_species_licenses_issued
    from {{ ref('dim_licenses') }} l
    join {{ ref('dim_date') }} d on d.date_key = l.license_issue_date_key
    where l.cp is not null
    group by l.cp, d.year
), combined as (
    select coalesce(c.cp, l.cp) as cp, coalesce(c.year, l.year) as year,
           coalesce(c.total_crimes, 0) as total_crimes,
           coalesce(l.total_licenses_issued, 0) as total_licenses_issued,
           coalesce(l.dog_licenses_issued, 0) as dog_licenses_issued,
           coalesce(l.cat_licenses_issued, 0) as cat_licenses_issued,
           coalesce(l.other_species_licenses_issued, 0) as other_species_licenses_issued,
           coalesce(l.unknown_species_licenses_issued, 0) as unknown_species_licenses_issued,
           c.total_crimes is not null as has_crime_records,
           l.total_licenses_issued is not null as has_license_records
    from crimes_by_cp_year c
    full outer join licenses_by_cp_year l on c.cp = l.cp and c.year = l.year
)
select m.*, p.geography is not null as has_geography, p.boundary_version,
       1000.0 * m.total_crimes / nullif(m.total_licenses_issued, 0) as crimes_per_1000_licenses_issued
from combined m
left join {{ ref('dim_postal_codes') }} p on p.cp = m.cp
