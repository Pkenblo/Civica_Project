select s.offense_type_id
from {{ ref('offense_types') }} s
full outer join {{ ref('dim_offense_types') }} d on d.offense_type_id = s.offense_type_id
where s.offense_type_id is null or d.offense_type_id is null
   or not equal_null(s.offense_type_original_values, d.offense_type_original_values)
