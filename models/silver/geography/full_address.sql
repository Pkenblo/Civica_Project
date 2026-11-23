{{ config(materialized='table') }}

with observations as (
    select block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_crimes') }}
    union all
    select block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_arrests') }}
),
normalized as (
    select o.* replace ({{ address_coordinate('o', 'latitude') }} as latitude,
                        {{ address_coordinate('o', 'longitude') }} as longitude)
    from observations o
    where not coalesce(is_location_redacted, false)
),
abstract_locations as (
    select 'UNKNOWN' as address_id, false as is_location_redacted
    union all
    select 'REDACTED', true
),
locations as (
    -- Los indicadores describen la calidad observada, no crean otra identidad.
    select {{ address_id('n') }} as address_id,
           block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           false as is_location_redacted,
           coalesce(boolor_agg(has_missing_coordinates), false) as has_missing_coordinates,
           coalesce(boolor_agg(has_invalid_coordinates), false) as has_invalid_coordinates
    from normalized n
    where block_address is not null or latitude is not null or longitude is not null
       or neighborhood is not null or reporting_area is not null or census_block_2020 is not null
    group by 1, 2, 3, 4, 5, 6, 7
    union all
    select address_id, null, null, null, null, null, null, is_location_redacted, true, false
    from abstract_locations
),
points as (
    -- Las coordenadas policiales se interpretan como EPSG:4326 (longitud, latitud).
    select distinct latitude, longitude,
           case when latitude between -90 and 90 and longitude between -180 and 180
                then st_makepoint(longitude, latitude) end as point
    from locations
    -- La calidad observada no invalida un par que ya ha superado la normalización RAW.
    where not is_location_redacted
      and latitude between -90 and 90 and longitude between -180 and 180
),
matches as (
    select p.latitude, p.longitude, count(z.cp) as covered, min(z.cp) as candidate_cp,
           count_if(st_contains(z.geography, p.point)) as interiors
    from points p
    left join {{ ref('postal_codes') }} z on st_covers(z.geography, p.point)
    group by p.latitude, p.longitude
),
classified as (
    select l.*, m.candidate_cp,
           case when l.is_location_redacted then 'redacted'
                when l.latitude is null or l.longitude is null
                    then iff(l.has_invalid_coordinates and not l.has_missing_coordinates,
                             'invalid_coordinates', 'missing_coordinates')
                when coalesce(m.covered, 0) = 0 then 'no_match'
                when m.covered > 1 then 'ambiguous'
                when coalesce(m.interiors, 0) = 0 then 'boundary'
                else 'matched' end as cp_status
    from locations l left join matches m using (latitude, longitude)
)
select classified.* exclude (candidate_cp), iff(cp_status = 'matched', candidate_cp, null) as cp
from classified
