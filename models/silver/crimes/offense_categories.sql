{{ config(materialized='table') }}

select distinct md5(offense_category) as offense_category_id, offense_category
from {{ ref('stg_crimes') }}
where offense_category is not null
