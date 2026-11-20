{{ config(materialized='table') }}

with crimes_by_severity as (
    select a.cp, d.year,
           sum(iff(n.severity = 'grave', c.crime_count, 0)) as serious_crimes,
           sum(iff(n.severity = 'leve', c.crime_count, 0)) as minor_crimes,
           sum(iff(coalesce(n.severity, 'sin_clasificar') = 'sin_clasificar',
                   c.crime_count, 0)) as unclassified_crimes
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    join {{ ref('dim_date') }} d on d.date_key = c.offense_date_key
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    where a.cp is not null
    group by a.cp, d.year
), combined as (
    select m.*, coalesce(s.serious_crimes, 0) as serious_crimes,
           coalesce(s.minor_crimes, 0) as minor_crimes,
           coalesce(s.unclassified_crimes, 0) as unclassified_crimes
    from {{ ref('mart_cp_crimes_pets') }} m
    left join crimes_by_severity s on s.cp = m.cp and s.year = m.year
)
select *,
       100.0 * serious_crimes / nullif(serious_crimes + minor_crimes, 0) as pct_serious_of_classified,
       100.0 * minor_crimes / nullif(serious_crimes + minor_crimes, 0) as pct_minor_of_classified,
       100.0 * (serious_crimes + minor_crimes) / nullif(total_crimes, 0) as pct_severity_coverage
from combined
