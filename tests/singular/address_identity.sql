select d.address_id
from {{ ref('full_address') }} d
where d.address_id is distinct from {{ address_id('d') }}
