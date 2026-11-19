-- Catálogo NIBRS obtenido de delitos. Grano previsto: un registro por offense_code.
-- Staging ya normaliza los textos; no crea una clasificación ficticia para códigos ausentes.
-- DISTINCT elimina duplicados completos. Si un código presenta atributos distintos,
-- conserva las variantes y las pruebas de unicidad detectan el conflicto.

with classifications as (

    select distinct
          nibrs_offense_code             as offense_code
        , nibrs_offense_code_description as offense_description
        , nibrs_group_a_b                as group_ab
        , nibrs_crime_against_category   as crime_against_category
    from {{ ref('stg_crimes') }}
    where nibrs_offense_code is not null

)

select
      {{ dbt_utils.generate_surrogate_key(['offense_code']) }} as nibrs_key
    , offense_code
    , offense_description
    , group_ab
    , crime_against_category
from classifications
