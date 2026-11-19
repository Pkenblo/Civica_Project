-- Catálogo postal: una fila por CP, uniendo las piezas de una sola versión activa.
-- Incluye CP válidos de licencias aunque no tengan geometría en la cartografía local.
-- La versión actual queda fijada, no se escoge la última carga automáticamente.
-- Para otra descarga, configurar zipcode_boundary_version y zipcode_expected_feature_count.
-- El pre_hook bloquea la materialización si el mapa falta, está incompleto o tiene datos inválidos.

{% set boundary_version = var('zipcode_boundary_version', 'kingcounty_download_2026-11-19') %}
{% set expected_features = var('zipcode_expected_feature_count', 273) | int %}

{% set validate_map %}
    select to_number(iff(
        count(*) = {{ expected_features }}
        and count(*) > 0
        and count(distinct object_id) = count(*)
        and coalesce(count_if(zip_code is null or not regexp_like(zip_code, '^[0-9]{5}$')), 0) = 0
        and coalesce(count_if(
            geography is null
            or not st_isvalid(geography)
            or coalesce(st_asgeojson(geography):type::varchar not in ('Polygon', 'MultiPolygon'), true)
        ), 0) = 0,
        '1',
        'Cartografia ausente o invalida: revisar version, recuento, IDs, CP y poligonos'
    )) as map_is_valid
    from {{ ref('stg_zipcode_areas') }}
    where boundary_version = '{{ boundary_version | replace("'", "''") }}'
{% endset %}

{{ config(
    materialized='table',
    database=env_var('DBT_SILVER'),
    schema='SILVER',
    pre_hook=validate_map
) }}

with selected_areas as (

    select zip_code as cp, geography, boundary_version
    from {{ ref('stg_zipcode_areas') }}
    where boundary_version = '{{ boundary_version | replace("'", "''") }}'

),

zones as (

    select cp, st_union_agg(geography) as geography, boundary_version
    from selected_areas
    group by cp, boundary_version

),

postal_catalog as (

    select cp
    from zones

    union

    select zip_code as cp
    from {{ ref('stg_pet_licenses') }}
    where regexp_like(zip_code, '^[0-9]{5}$')

)

select
      catalog.cp
    , zones.geography
    , zones.boundary_version
from postal_catalog as catalog
left join zones
    on catalog.cp = zones.cp
