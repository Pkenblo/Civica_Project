-- Catálogo de tipos de tiroteo distintos y no nulos recibidos de staging.
-- No convierte una etiqueta ausente en un tipo ficticio ni vuelve a limpiar el texto.

with deduplicated as (

    select distinct shooting_type_group as description
    from {{ ref('stg_crimes') }}
    where shooting_type_group is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key(['description']) }} as shooting_type_id
        , description
    from deduplicated

)

{{ changed_catalog_rows('candidates') }}
