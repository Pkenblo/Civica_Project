with expected as (
    select p.cp, y.year, o.offense_classification_id
    from {{ ref('dim_postal_codes') }} p
    cross join (
        select distinct year(offense_date) as year
        from {{ ref('fact_crimes') }} where offense_date is not null
    ) y
    cross join (
        select offense_classification_id from {{ ref('dim_offense_classification') }}
        union all select null::varchar
    ) o
)

select coalesce(e.cp, m.cp) as cp, coalesce(e.year, m.year) as year,
       coalesce(e.offense_classification_id, m.offense_classification_id) as offense_classification_id
from expected e
full outer join {{ ref('mart_crime_socioeconomic') }} m
    on m.cp = e.cp and m.year = e.year
    and equal_null(m.offense_classification_id, e.offense_classification_id)
where e.cp is null or m.cp is null
