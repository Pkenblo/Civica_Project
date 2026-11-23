select
      address_id
    , block_address
    , latitude
    , longitude
    , neighborhood
    , reporting_area
    , census_block_2020
    , cp
    , cp_status
    , is_location_redacted
    , has_missing_coordinates
    , has_invalid_coordinates
from {{ ref('full_address') }}
