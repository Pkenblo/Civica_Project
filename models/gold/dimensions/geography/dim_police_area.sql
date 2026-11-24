select
      police_area_id
    , precinct
    , sector
    , beat
from {{ ref('police_add') }}
