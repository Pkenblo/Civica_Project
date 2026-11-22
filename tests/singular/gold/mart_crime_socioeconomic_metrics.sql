with totals as (
    select cp, year, sum(crime_count) as crime_count
    from {{ ref('mart_crime_socioeconomic') }}
    group by cp, year
),

expected as (
    select m.*, t.crime_count as expected_total,
           m.crime_count * 1000.0 / nullif(m.population, 0) as expected_rate,
           t.crime_count * 1000.0 / nullif(m.population, 0) as expected_total_rate,
           m.crime_count * 100.0 / nullif(t.crime_count, 0) as expected_share
    from {{ ref('mart_crime_socioeconomic') }} m
    join totals t on t.cp = m.cp and t.year = m.year
)

select cp, year, offense_classification_id
from expected
where postal_year_crime_count is distinct from expected_total
   or (crimes_per_1000 is null) <> (expected_rate is null)
   or abs(crimes_per_1000 - expected_rate) > 0.000001
   or (postal_year_crimes_per_1000 is null) <> (expected_total_rate is null)
   or abs(postal_year_crimes_per_1000 - expected_total_rate) > 0.000001
   or (crime_share_pct is null) <> (expected_share is null)
   or abs(crime_share_pct - expected_share) > 0.000001
