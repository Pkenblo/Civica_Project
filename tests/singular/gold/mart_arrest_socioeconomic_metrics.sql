with totals as (
    select a.cp, year(r.arrest_occurred_date) as year, count(distinct r.arrest_number) as arrest_count
    from {{ ref('fact_arrests') }} r
    join {{ ref('dim_address') }} a on a.address_id = r.address_id
    where r.arrest_occurred_date is not null
      and exists (select 1 from {{ ref('dim_postal_codes') }} p where p.cp = a.cp)
    group by a.cp, year(r.arrest_occurred_date)
),

expected as (
    select m.arrest_number, m.postal_year_arrest_count, m.postal_year_arrests_per_1000,
           t.arrest_count as expected_total,
           t.arrest_count * 1000.0 / nullif(m.population, 0) as expected_rate
    from {{ ref('mart_arrest_socioeconomic') }} m
    left join totals t on t.cp = m.cp and t.year = m.year
)

select arrest_number
from expected
where postal_year_arrest_count is distinct from expected_total
   or (postal_year_arrests_per_1000 is null) <> (expected_rate is null)
   or abs(postal_year_arrests_per_1000 - expected_rate) > 0.000001
