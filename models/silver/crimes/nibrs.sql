{{ config(materialized='table') }}

select md5(nibrs_offense_code) as nibrs_key, nibrs_offense_code as offense_code,
       nibrs_offense_code_description as offense_description, nibrs_group_a_b as group_ab,
       nibrs_crime_against_category as crime_against_category
from {{ ref('stg_crimes') }}
where nibrs_offense_code is not null
qualify row_number() over (
    partition by nibrs_offense_code
    order by ingested_at desc nulls last, source_file desc nulls last, batch_id desc nulls last,
             nibrs_offense_code_description desc nulls last, nibrs_group_a_b desc nulls last,
             nibrs_crime_against_category desc nulls last
) = 1
