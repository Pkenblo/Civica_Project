-- Catálogo de infracciones de arresto, independiente de la clasificación NIBRS de delitos.
-- Una fila por offense_type distinto y no nulo; staging ya ha normalizado el texto.

{{ config(materialized='table', database=env_var('DBT_SILVER'), schema='SILVER') }}

with deduplicated as (

    select distinct offense_type
    from {{ ref('stg_arrests') }}
    where offense_type is not null

)

select
      {{ dbt_utils.generate_surrogate_key(['offense_type']) }} as offense_type_id
    , offense_type
from deduplicated
