select c.crime_id
from {{ ref('crimes') }} c
join {{ ref('offense_subcategories') }} s using (offense_subcategory_id)
where c.offense_category_id is distinct from s.offense_category_id
