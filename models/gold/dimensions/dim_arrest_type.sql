select arrest_type_id, 
       description
from {{ ref('arrest_types') }}
