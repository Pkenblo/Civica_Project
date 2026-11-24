{{ config(materialized='table') }}

with areas as (
    select
          precinct
        , sector
        , beat
    from {{ ref('stg_arrests') }}
    union
    select
          precinct
        , sector
        , beat
    from {{ ref('stg_crimes') }}
)

select
      {{ dbt_utils.generate_surrogate_key(['precinct', 'sector', 'beat']) }} as police_area_id
    , precinct
    , sector
    , beat
from areas
where precinct is not null or sector is not null or beat is not null
