-- Recuentos por detención, incluidas las que tienen cero cargos; detecta multiplicaciones de JOIN.
with observed as (
    select distinct arrest_number, offense_type, nibrs_description
    from {{ ref('stg_arrests') }}
    where offense_type is not null or nibrs_description is not null
),
expected as (
    select a.arrest_number, count(o.arrest_number) as offense_count
    from {{ ref('arrest') }} a
    left join observed o on o.arrest_number = a.arrest_number
    group by a.arrest_number
),
actual as (
    select a.arrest_number, count(d.arrest_offense_id) as offense_count
    from {{ ref('fact_arrests') }} a
    left join {{ ref('bridge_arrest_offenses') }} d on d.arrest_number = a.arrest_number
    group by a.arrest_number
)
select coalesce(e.arrest_number, a.arrest_number) as arrest_number,
       e.offense_count as expected_count, a.offense_count as actual_count
from expected e
full outer join actual a on a.arrest_number = e.arrest_number
where e.arrest_number is null or a.arrest_number is null or e.offense_count <> a.offense_count
