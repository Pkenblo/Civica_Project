{{ config(materialized='table') }}

select distinct
      {{ dbt_utils.generate_surrogate_key(['cad_clearance', 'cad_initial_call_type', 'cad_priority']) }} as cad_profile_id
    , cad_clearance
    , cad_initial_call_type
    , cad_priority
from {{ ref('stg_arrests') }}
where cad_clearance is not null or cad_initial_call_type is not null or cad_priority is not null
