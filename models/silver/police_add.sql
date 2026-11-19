-- Catálogo común de áreas policiales de delitos y arrestos.
-- Grano: una combinación de precinct, sector y beat, no una fila por beat.

with police_areas as (

    select precinct, sector, beat
    from {{ ref('stg_crimes') }}

    union all

    select precinct, sector, beat
    from {{ ref('stg_arrests') }}

),

deduplicated as (

    select distinct precinct, sector, beat
    from police_areas
    -- Conserva áreas parciales, sin inventar una entidad para la ausencia total.
    where precinct is not null or sector is not null or beat is not null

)

select
      {{ dbt_utils.generate_surrogate_key(['precinct', 'sector', 'beat']) }} as police_area_id
    , precinct
    , sector
    , beat
from deduplicated
