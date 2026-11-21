with categories as (
    select offense_category_id, offense_category
    from {{ ref('offense_categories') }}
), classifications as (
    select s.offense_category_id, s.offense_subcategory_id, c.offense_category, s.offense_sub_category
    from {{ ref('offense_subcategories') }} s
    left join categories c on c.offense_category_id = s.offense_category_id

    union all

    -- Cada categoría puede llegar sin subcategoría, incluso si también tiene hijas.
    select offense_category_id, null::varchar as offense_subcategory_id,
           offense_category, null::varchar as offense_sub_category
    from categories
)
select md5(to_json(array_construct(offense_category_id, offense_subcategory_id))) as offense_classification_id,
       offense_category_id, offense_subcategory_id, offense_category, offense_sub_category
from classifications
