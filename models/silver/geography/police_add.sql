-- Catálogo común de áreas policiales de delitos y arrestos.
-- Grano: una combinación de precinct, sector y beat, no una fila por beat.

with consolidated as (

    {{ consolidate_arrests(ref('stg_arrests')) }}

),

police_areas as (

    select precinct, sector, beat
    from {{ ref('stg_crimes') }}

    union all

    select precinct, sector, beat
    from {{ ref('stg_arrests') }}

    union all

    select precinct, sector, beat
    from consolidated

),

deduplicated as (

    select distinct precinct, sector, beat
    from police_areas
    -- Conserva áreas parciales, sin inventar una entidad para la ausencia total.
    where precinct is not null or sector is not null or beat is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key(['precinct', 'sector', 'beat']) }} as police_area_id
        , precinct
        , sector
        , beat
    from deduplicated

)

select * from candidates
{% if is_incremental() %}
where police_area_id in (
    select police_area_id
    from (
        select * from candidates
        except
        select police_area_id, precinct, sector, beat
        from {{ this }}
    ) as differences
)
{% endif %}
