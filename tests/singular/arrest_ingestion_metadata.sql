-- La detección de versiones exige una fecha real de ingesta, nunca la fecha del hecho.
select arrest_number, batch_id, source_file, ingested_at
from {{ ref('stg_arrests') }}
where arrest_number is not null
  and ingested_at is null
