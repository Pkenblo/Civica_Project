{% set version = var('zipcode_boundary_version', 'kingcounty_download_2026-11-19') | replace("'", "''") %}
{{ config(materialized='table') }}

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
