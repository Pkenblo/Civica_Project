select {{ dbt_utils.generate_surrogate_key([dbt_utils.generate_surrogate_key(['report_number']), 'offense_id']) }} as crime_id,
       {{ dbt_utils.generate_surrogate_key(['shooting_type_group']) }} as shooting_type_id
from {{ ref('stg_crimes') }}
where shooting_type_group is not null
minus
select crime_id, shooting_type_id from {{ ref('crime_shooting_types') }}
