-- Catálogo de tipos de arresto. Los identificadores dependen de la descripción
-- recibida de staging, no del orden de las filas ni de una numeración que pueda cambiar.

with deduplicated as (

    select distinct arrest_type as description
    from {{ ref('stg_arrests') }}
    where arrest_type is not null

)

select
      {{ dbt_utils.generate_surrogate_key(['description']) }} as arrest_type_id
    , description
from deduplicated
