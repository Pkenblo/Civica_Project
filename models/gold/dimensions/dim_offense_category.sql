select offense_category_id, offense_category
from {{ ref('offense_categories') }}
