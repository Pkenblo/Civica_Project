{% set version = var('zipcode_boundary_version', 'kingcounty_download_2026-11-19') | replace("'", "''") %}
{% set validate_map %}
    select to_number(iff(
        count(*) = {{ var('zipcode_expected_feature_count', 273) | int }} and count(*) > 0
        and count(distinct object_id) = count(*)
        and coalesce(count_if(zip_code is null or not regexp_like(zip_code, '^[0-9]{5}$')
                     or geography is null or not st_isvalid(geography)
                     or st_asgeojson(geography):type::varchar not in ('Polygon', 'MultiPolygon')), 0) = 0,
        '1', 'Cartografía incompleta o inválida: revisar versión, recuento, IDs, CP y geometrías'
    ))
    from {% raw %}{{ ref('stg_zipcode_areas') }}{% endraw %}
    where boundary_version = '{{ version }}'
{% endset %}
{{ config(materialized='table', pre_hook=validate_map) }}

with zones as (
    select zip_code as cp, st_union_agg(geography) as geography, boundary_version
    from {{ ref('stg_zipcode_areas') }}
    where boundary_version = '{{ version }}'
    group by zip_code, boundary_version
),
codes as (
    select cp from zones
    union
    select zip_code from {{ ref('stg_pet_licenses') }} where regexp_like(zip_code, '^[0-9]{5}$')
)
select codes.cp, zones.geography, zones.boundary_version
from codes left join zones using (cp)
