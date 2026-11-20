{{ config(unique_key='address_id', post_hook="{{ gold_prune_missing_keys(ref('full_address'), 'address_id') }}") }}

with current_rows as (
select address_id, block_address, latitude, longitude, neighborhood, reporting_area,
       census_block_2020, cp, cp_status, is_location_redacted, has_missing_coordinates,
       has_invalid_coordinates
from {{ ref('full_address') }}
)
{{ gold_changed_rows() }}
