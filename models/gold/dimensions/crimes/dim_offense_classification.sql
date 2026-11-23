select
    offense_category_id as offense_classification_id,
    offense_category,
    offense_sub_category
from {{ ref('offense_categories') }}