select cad_profile_id, cad_clearance, cad_initial_call_type, cad_priority
from {{ ref('cad_profiles') }}
