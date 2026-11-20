{% set validate_crs %}
    select to_number(iff({{ 'true' if var('police_coordinates_epsg4326_confirmed', false) == true else 'false' }},
                         '1', 'Confirmar documentalmente el CRS policial EPSG:4326'))
{% endset %}
{{ config(materialized='table', pre_hook=validate_crs) }}

with observations as (
    select 'C:' || md5(report_number) || ':' || offense_id as event_key,
           block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_crimes') }}
    union all
    select 'A:' || arrest_number, block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_arrests') }}
),
locations as (
    select distinct * exclude (event_key),
           iff(is_location_redacted or has_missing_coordinates or has_invalid_coordinates, event_key, null) as location_context
    from observations
),
points as (
    select distinct latitude, longitude,
           case when latitude between -90 and 90 and longitude between -180 and 180
                then st_makepoint(longitude, latitude) end as point
    from locations
    where not (is_location_redacted or has_missing_coordinates or has_invalid_coordinates)
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
                when l.has_missing_coordinates then 'missing_coordinates'
                when l.has_invalid_coordinates then 'invalid_coordinates'
                when coalesce(m.covered, 0) = 0 then 'no_match'
                when m.covered > 1 then 'ambiguous'
                when coalesce(m.interiors, 0) = 0 then 'boundary'
                else 'matched' end as cp_status
    from locations l left join matches m using (latitude, longitude)
)
select md5(to_json(array_construct(block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
                                   is_location_redacted, has_missing_coordinates, has_invalid_coordinates, location_context))) as address_id,
       classified.* exclude (candidate_cp), iff(cp_status = 'matched', candidate_cp, null) as cp
from classified
