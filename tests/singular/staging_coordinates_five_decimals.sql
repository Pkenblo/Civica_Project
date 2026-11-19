-- Los valores que reciben las tablas Silver ya tienen cinco decimales como máximo.
select 'crimes' as source_name, offense_id as source_id, latitude, longitude
from {{ ref('stg_crimes') }}
where latitude <> round(latitude, 5) or longitude <> round(longitude, 5)

union all

select 'arrests' as source_name, arrest_number as source_id, latitude, longitude
from {{ ref('stg_arrests') }}
where latitude <> round(latitude, 5) or longitude <> round(longitude, 5)
