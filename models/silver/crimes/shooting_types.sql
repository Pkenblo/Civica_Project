{{ config(materialized='table') }}

select distinct {{ dbt_utils.generate_surrogate_key(['shooting_type_group']) }} as shooting_type_id, shooting_type_group as description
from {{ ref('stg_crimes') }}
where shooting_type_group is not null
