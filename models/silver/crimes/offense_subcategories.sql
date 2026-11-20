{{ config(materialized='table') }}

select distinct
    md5(to_json(array_construct(s.offense_category, s.offense_sub_category))) as offense_subcategory_id,
    c.offense_category_id, s.offense_sub_category
from {{ ref('stg_crimes') }} s
left join {{ ref('offense_categories') }} c on s.offense_category = c.offense_category
where s.offense_sub_category is not null
