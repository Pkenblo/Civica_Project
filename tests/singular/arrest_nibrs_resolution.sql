-- Comprueba tanto las FKs resueltas como el tratamiento explícito de excepciones y nulos.
with expected as (
    select distinct
           {{ dbt_utils.generate_surrogate_key(['s.arrest_number', 's.offense_type', 's.nibrs_description']) }} as arrest_offense_id,
           s.nibrs_description
    from {{ ref('stg_arrests') }} s
),
matches as (
    select offense_description, count(*) as match_count, min(nibrs_key) as nibrs_key
    from {{ ref('nibrs') }}
    group by offense_description
)
select d.arrest_offense_id
from {{ ref('arrest_offenses') }} d
join expected e on e.arrest_offense_id = d.arrest_offense_id
left join matches m on m.offense_description = e.nibrs_description
where not equal_null(d.nibrs_match_status,
          case when e.nibrs_description is null then 'missing'
               when m.match_count = 1 then 'matched'
               when m.match_count > 1 then 'ambiguous' else 'unmatched' end)
   or not equal_null(d.nibrs_key, iff(m.match_count = 1, m.nibrs_key, null))
   or not equal_null(d.unresolved_nibrs_description,
          iff(coalesce(m.match_count, 0) <> 1, e.nibrs_description, null))
