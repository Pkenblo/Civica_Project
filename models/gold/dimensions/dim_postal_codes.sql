select cp, geography, boundary_version
from {{ ref('postal_codes') }}
