-- Toda asociación legítima de staging debe seguir en el detalle, aunque cambie el hecho.
select distinct source.arrest_number, source.offense_type, source.nibrs_description
from {{ ref('stg_arrests') }} as source
where source.arrest_number is not null
  and (source.offense_type is not null or source.nibrs_description is not null)
  and not exists (
      select 1
      from {{ ref('arrest_offenses') }} as detail
      left join {{ ref('offense_types') }} as types on detail.offense_type_id = types.offense_type_id
      where detail.arrest_number = source.arrest_number
        and equal_null(types.offense_type, source.offense_type)
        and equal_null(detail.nibrs_description, source.nibrs_description)
  )
