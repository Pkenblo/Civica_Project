-- Ubicaciones publicadas: atributos normalizados y contexto, no direcciones postales exactas.
-- La clave no depende del CP, cp_status ni de la versión cartográfica.
-- Ubicaciones ocultadas, ausentes o inválidas se separan por origen e ID del hecho,
-- sin convertir todas las ausencias en una dirección real compartida.
-- El cruce solo asigna CP a una coincidencia interior única. No busca el CP más cercano.
-- IMPORTANTE: confirmar documentalmente el CRS policial antes de materializar este modelo.
-- El pre_hook exige police_coordinates_epsg4326_confirmed=true; por defecto bloquea el build.

{% set confirmed_crs = var('police_coordinates_epsg4326_confirmed', false) %}
{% set validate_crs %}
    select to_number(iff(
        coalesce(try_to_boolean('{{ confirmed_crs | string | replace("'", "''") }}'), false),
        '1',
        'Confirmar CRS policial EPSG:4326 antes de activar police_coordinates_epsg4326_confirmed'
    )) as police_crs_is_confirmed
{% endset %}

{{ config(
    materialized='table',
    database=env_var('DBT_SILVER'),
    schema='SILVER',
    pre_hook=validate_crs
) }}

with consolidated as (

    {{ consolidate_arrests(ref('stg_arrests')) }}

),

source_locations as (

    select
          'crimes' as source_name
        , offense_id as source_id
        , block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_crimes') }}
    where offense_id is not null

    union all

    select
          'arrests' as source_name
        , arrest_number as source_id
        , block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_arrests') }}
    where arrest_number is not null

    union all

    -- El hecho puede combinar atributos no nulos de varios lotes; cataloga esa misma ubicación.
    select
          'arrests' as source_name
        , arrest_number as source_id
        , block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from consolidated

),

locations as (

    select distinct
          block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
        , case
            when is_location_redacted or has_missing_coordinates or has_invalid_coordinates
                then source_name || ':' || source_id
            else null
          end as location_context
    from source_locations

),

keyed_locations as (

    -- Mismos campos y orden que en crimes.sql y arrest.sql.
    select
          {{ dbt_utils.generate_surrogate_key([
              'block_address', 'latitude', 'longitude', 'neighborhood',
              'reporting_area', 'census_block_2020', 'is_location_redacted',
              'has_missing_coordinates', 'has_invalid_coordinates', 'location_context'
          ]) }} as address_id
        , locations.*
    from locations

),

eligible_coordinates as (

    -- Se evalúa cada par elegible una vez, sin fusionar el contexto de sus ubicaciones.
    select distinct
          latitude
        , longitude
        , case
            when latitude between -90 and 90 and longitude between -180 and 180
                then st_makepoint(longitude, latitude)
          end as point
    from locations
    where not is_location_redacted
      and not has_missing_coordinates
      and not has_invalid_coordinates
      and latitude is not null
      and longitude is not null

),

zones as (

    select cp, geography
    from {{ ref('postal_codes') }}
    where geography is not null

),

assignments as (

    select
          points.latitude
        , points.longitude
        , count(distinct zones.cp) as candidate_count
        , min(zones.cp) as candidate_cp
        , coalesce(count_if(st_contains(zones.geography, points.point)), 0) as interior_count
    from eligible_coordinates as points
    left join zones
        on st_covers(zones.geography, points.point)
    group by points.latitude, points.longitude

),

classified as (

    select
          locations.address_id
        , locations.block_address
        , locations.latitude
        , locations.longitude
        , locations.neighborhood
        , locations.reporting_area
        , locations.census_block_2020
        , assignments.candidate_cp
        , case
            when locations.is_location_redacted then 'redacted'
            when locations.has_missing_coordinates then 'missing_coordinates'
            when locations.has_invalid_coordinates then 'invalid_coordinates'
            when coalesce(assignments.candidate_count, 0) = 0 then 'no_match'
            when assignments.candidate_count > 1 then 'ambiguous'
            when coalesce(assignments.interior_count, 0) = 0 then 'boundary'
            else 'matched'
          end as cp_status
    from keyed_locations as locations
    left join assignments
        on locations.latitude = assignments.latitude
        and locations.longitude = assignments.longitude

)

select
      address_id
    , block_address
    , latitude
    , longitude
    , neighborhood
    , reporting_area
    , census_block_2020
    , case when cp_status = 'matched' then candidate_cp else null end as cp
    , cp_status
from classified
