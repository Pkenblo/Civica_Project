select license_number, max(ingested_at) as ingested_at
from {{ ref('stg_pet_licenses') }}
group by license_number
minus
select license_number, ingested_at from {{ ref('licenses') }}
