-- Auditoría de conflictos sin descartar versiones de RAW ni forzar una prueba a fallar.
{{ config(materialized='view', database=env_var('DBT_SILVER'), schema='SILVER') }}

select
      arrest.arrest_number
    , conflict.key::varchar as field_name
    , conflict.value as observed_values
    , get(arrest.consolidation_choices, conflict.key) as selected_value
    , arrest.max_completeness_score
    , arrest.last_ingested_at
from {{ ref('arrest') }} as arrest,
     lateral flatten(input => arrest.consolidation_conflicts) as conflict
