{{ config(materialized='table') }}

select distinct md5(shooting_type_group) as shooting_type_id, shooting_type_group as description
from {{ ref('stg_crimes') }}
where shooting_type_group is not null
