{{ config(severity='error') }}

-- Las filas censuradas no deben conservar ningún atributo de ubicación.
select
      arrest_number
    , ingested_at
from {{ ref('stg_arrests') }}
where is_location_redacted
  and (
      block_address is not null
      or latitude is not null
      or longitude is not null
      or neighborhood is not null
      or reporting_area is not null
      or census_block_2020 is not null
  )
