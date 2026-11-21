{{ config(materialized='ephemeral') }}

select arrest_offense_id, arrest_number, offense_type, nibrs_description
from {{ ref('arrest_offenses') }}
