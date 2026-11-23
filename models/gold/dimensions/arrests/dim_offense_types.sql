select offense_type_id, 
       offense_type, 
       offense_type_original_values,
       legal_source, 
       legal_code, 
       secondary_legal_source, 
       secondary_legal_code, 
       external_code,
       offense_description, 
       offense_category, 
       parse_status, 
       ingested_at
from {{ ref('offense_types') }}
