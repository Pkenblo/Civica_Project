{{ config(materialized='table') }}

-- El delta RAW transmite filas observadas; no transmite bajas de etiquetas.
with observations as (
    select distinct
          {{ dbt_utils.generate_surrogate_key(['report_number']) }} as report_id
        , offense_id
        , shooting_type_group
    from {{ ref('stg_crimes') }}
    where shooting_type_group is not null
)

select
      c.crime_id
    , t.shooting_type_id
from observations o
join {{ ref('crimes') }} c on c.report_id = o.report_id and c.offense_id = o.offense_id
join {{ ref('shooting_types') }} t on t.description = o.shooting_type_group
