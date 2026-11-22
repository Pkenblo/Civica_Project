-- El enriquecimiento no debe añadir, eliminar ni duplicar delitos del mapa.
with expected as (
    select c.crime_id
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    where a.block_address is not null
      and not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
      and a.latitude between -90 and 90 and a.longitude between -180 and 180
),

actual as (
    select crime_id, count(*) as row_count
    from {{ ref('mart_crimes_socioeconomic') }}
    group by crime_id
)

select e.crime_id
from expected e
left join actual m on m.crime_id = e.crime_id
where m.crime_id is null or m.row_count <> 1

union all

select m.crime_id
from actual m
left join expected e on e.crime_id = m.crime_id
where e.crime_id is null
