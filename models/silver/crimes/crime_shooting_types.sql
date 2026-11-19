-- Puente N:M: una fila por pareja (offense_id, shooting_type_id).
-- Extrae las asociaciones de staging antes de deduplicar la futura tabla Crimes.
-- Conserva varios tipos por delito y elimina solo parejas repetidas.
-- Sin ID o etiqueta no se inventa una asociación. LEFT JOIN permite detectar con
-- not_null un tipo ausente del catálogo, en vez de perderlo silenciosamente.

select distinct
      crimes.offense_id
    , shooting_types.shooting_type_id
from {{ ref('stg_crimes') }} as crimes
left join {{ ref('shooting_types') }} as shooting_types
    on crimes.shooting_type_group = shooting_types.description
where crimes.offense_id is not null
  and crimes.shooting_type_group is not null
