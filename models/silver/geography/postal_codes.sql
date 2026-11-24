{% set version = var('zipcode_boundary_version', 'kingcounty_download_2026-11-19') | replace("'", "''") %}
{{ config(
    materialized='table',
    tags=['static_model']
) }}

with zones as (
    select
          zip_code as cp
        , st_union_agg(geography) as geography
        , boundary_version
    from {{ ref('stg_zipcode_areas') }}
    where boundary_version = '{{ version }}'
    group by
          zip_code
        , boundary_version
)

select
      cp
    , geography
    , boundary_version
from zones
