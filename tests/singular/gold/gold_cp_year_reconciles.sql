-- Independent control totals at the output grain, for each source and severity.
with eligible_crimes as (
    select a.cp, year(c.offense_date_time) as year,
           count(*) as crimes,
           count_if(n.severity = 'grave') as serious,
           count_if(n.severity = 'leve') as minor,
           count_if(n.severity is null or n.severity = 'sin_clasificar') as unclassified
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    where a.cp is not null and c.offense_date_time is not null
    group by 1, 2
), eligible_licenses as (
    select cp, year(license_issue_date) as year, count(*) as licenses,
           count_if(species_group = 'dog') as dogs, count_if(species_group = 'cat') as cats,
           count_if(species_group = 'other') as others, count_if(species_group = 'unknown') as unknowns
    from {{ ref('dim_licenses') }}
    where cp is not null and license_issue_date is not null
    group by 1, 2
), keys as (
    select cp, year from eligible_crimes
    union
    select cp, year from eligible_licenses
)
select m.cp as mart_cp, m.year as mart_year, k.cp as expected_cp, k.year as expected_year
from keys k
full outer join {{ ref('mart_cp_crimes_pets_severity') }} m on k.cp = m.cp and k.year = m.year
left join eligible_crimes c on k.cp = c.cp and k.year = c.year
left join eligible_licenses l on k.cp = l.cp and k.year = l.year
left join {{ ref('dim_postal_codes') }} p on p.cp = k.cp
where k.cp is null or m.cp is null
    or m.total_crimes is distinct from coalesce(c.crimes, 0)
    or m.total_licenses_issued is distinct from coalesce(l.licenses, 0)
    or m.serious_crimes is distinct from coalesce(c.serious, 0)
    or m.minor_crimes is distinct from coalesce(c.minor, 0)
    or m.unclassified_crimes is distinct from coalesce(c.unclassified, 0)
    or m.dog_licenses_issued is distinct from coalesce(l.dogs, 0)
    or m.cat_licenses_issued is distinct from coalesce(l.cats, 0)
    or m.other_species_licenses_issued is distinct from coalesce(l.others, 0)
    or m.unknown_species_licenses_issued is distinct from coalesce(l.unknowns, 0)
    or m.has_geography is distinct from (p.geography is not null)
    or m.boundary_version is distinct from p.boundary_version
