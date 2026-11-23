{{ config(materialized='table') }}

select distinct
      {{ dbt_utils.generate_surrogate_key(['offense_category', 'offense_sub_category']) }} as offense_category_id
    , offense_category
    , offense_sub_category
from {{ ref('stg_crimes') }}
where offense_category is not null or offense_sub_category is not null
