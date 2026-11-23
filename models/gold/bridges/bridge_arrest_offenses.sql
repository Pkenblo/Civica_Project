select arrest_offense_id, arrest_number, offense_type_id, nibrs_key,
       nibrs_match_status, unresolved_nibrs_description
from {{ ref('arrest_offenses') }}
