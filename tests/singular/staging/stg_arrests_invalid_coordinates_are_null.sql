{{ config(severity='error') }}

-- Staging debe anular ambas coordenadas si el par RAW es inválido.
select
      arrest_number
    , ingested_at
from {{ ref('stg_arrests') }}
where has_invalid_coordinates
  and (
      latitude is not null
      or longitude is not null
  )
