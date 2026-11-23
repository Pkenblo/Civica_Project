select shooting_type_id, 
       description
from {{ ref('shooting_types') }}
