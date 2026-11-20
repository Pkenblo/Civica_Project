{{ config(materialized='table') }}

with observations as (
    select distinct arrest_number, offense_type, nibrs_description
    from {{ ref('stg_arrests') }}
    where offense_type is not null or nibrs_description is not null
)
select md5(to_json(array_construct(a.arrest_number, o.offense_type, o.nibrs_description))) as arrest_offense_id,
       a.arrest_number, o.offense_type, o.nibrs_description
from observations o
join {{ ref('arrest') }} a on a.arrest_number = o.arrest_number
