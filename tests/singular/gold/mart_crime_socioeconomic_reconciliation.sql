with expected as (
    -- Independiente de la dimensión de clasificación y del contexto económico.
    select a.cp, year(c.offense_date) as year, c.offense_classification_id,
           count(distinct c.crime_id) as crime_count
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    where c.offense_date is not null
      and exists (select 1 from {{ ref('dim_postal_codes') }} p where p.cp = a.cp)
    group by a.cp, year(c.offense_date), c.offense_classification_id
),

actual as (
    select cp, year, offense_classification_id, sum(crime_count) as crime_count
    from {{ ref('mart_crime_socioeconomic') }}
    where crime_count > 0
    group by cp, year, offense_classification_id
)

select coalesce(e.cp, a.cp) as cp, coalesce(e.year, a.year) as year,
       coalesce(e.offense_classification_id, a.offense_classification_id) as offense_classification_id,
       e.crime_count as expected_count, a.crime_count as actual_count
from expected e
full outer join actual a on a.cp = e.cp and a.year = e.year
    and equal_null(a.offense_classification_id, e.offense_classification_id)
where e.crime_count is distinct from a.crime_count
