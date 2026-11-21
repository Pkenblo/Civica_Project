{{ config(materialized='ephemeral') }}

select crime_id, shooting_type_id
from {{ ref('crime_shooting_types') }}
