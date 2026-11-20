select offense_subcategory_id, offense_category_id, offense_sub_category
from {{ ref('offense_subcategories') }}
