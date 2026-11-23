-- Compara con el grano de staging, no con FKs recién calculadas.
-- Las detenciones aún no publicadas se controlan en arrest_source_ids_complete.
with expected as (
    select distinct s.arrest_number, s.offense_type, s.nibrs_description,
           {{ dbt_utils.generate_surrogate_key(['s.arrest_number', 's.offense_type', 's.nibrs_description']) }} as arrest_offense_id
    from {{ ref('stg_arrests') }} s
    join {{ ref('arrest') }} a on a.arrest_number = s.arrest_number
    where s.offense_type is not null or s.nibrs_description is not null
),
actual as (
    select d.arrest_offense_id, d.arrest_number, t.offense_type,
           coalesce(d.unresolved_nibrs_description, n.offense_description) as nibrs_description
    from {{ ref('arrest_offenses') }} d
    left join {{ ref('offense_types') }} t on t.offense_type_id = d.offense_type_id
    left join {{ ref('nibrs') }} n on n.nibrs_key = d.nibrs_key
)
select coalesce(e.arrest_offense_id, a.arrest_offense_id) as arrest_offense_id
from expected e
full outer join actual a on a.arrest_offense_id = e.arrest_offense_id
where e.arrest_offense_id is null or a.arrest_offense_id is null
   or not equal_null(e.arrest_number, a.arrest_number)
   or not equal_null(e.offense_type, a.offense_type)
   or not equal_null(e.nibrs_description, a.nibrs_description)
