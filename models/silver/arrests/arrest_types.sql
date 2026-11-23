{{ config(materialized='table') }}

select distinct
      {{ dbt_utils.generate_surrogate_key(['arrest_type']) }} as arrest_type_id
    , arrest_type as description
from {{ ref('stg_arrests') }}
where arrest_type is not null
