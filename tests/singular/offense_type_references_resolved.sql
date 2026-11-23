-- Todo texto legal de una detención publicada debe seguir en SU cargo y SU catálogo.
-- No basta con que la FK apunte a cualquier fila existente.
with expected as (
    select distinct s.arrest_number, s.offense_type,
           {{ dbt_utils.generate_surrogate_key(['s.arrest_number', 's.offense_type', 's.nibrs_description']) }} as arrest_offense_id
    from {{ ref('stg_arrests') }} s
    join {{ ref('arrest') }} a on a.arrest_number = s.arrest_number
    where s.offense_type is not null
)
select e.arrest_number, e.arrest_offense_id, e.offense_type
from expected e
left join {{ ref('arrest_offenses') }} d on d.arrest_offense_id = e.arrest_offense_id
left join {{ ref('offense_types') }} t on t.offense_type_id = d.offense_type_id
where d.arrest_offense_id is null or d.offense_type_id is null or t.offense_type_id is null
   or not equal_null(d.offense_type_id, {{ dbt_utils.generate_surrogate_key(['e.offense_type']) }})
   or not equal_null(t.offense_type, e.offense_type)
