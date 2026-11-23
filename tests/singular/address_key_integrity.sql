-- Detecta claves antiguas, referencias nulas y divergencias entre Silver y Gold.
select 'full_address' as model_name, address_id as key_value
from {{ ref('full_address') }}
group by address_id
having address_id is null or count(*) <> 1
union all
select 'dim_address', address_id
from {{ ref('dim_address') }}
group by address_id
having address_id is null or count(*) <> 1
union all
select 'crimes', c.crime_id
from {{ ref('crimes') }} c
left join {{ ref('full_address') }} d on d.address_id = c.address_id
where d.address_id is null
union all
select 'arrest', a.arrest_number
from {{ ref('arrest') }} a
left join {{ ref('full_address') }} d on d.address_id = a.address_id
where d.address_id is null
union all
select 'fact_crimes', f.crime_id
from {{ ref('fact_crimes') }} f
left join {{ ref('dim_address') }} d on d.address_id = f.address_id
left join {{ ref('crimes') }} c on c.crime_id = f.crime_id
where d.address_id is null or c.crime_id is null or f.address_id is distinct from c.address_id
union all
select 'fact_arrests', f.arrest_number
from {{ ref('fact_arrests') }} f
left join {{ ref('dim_address') }} d on d.address_id = f.address_id
left join {{ ref('arrest') }} a on a.arrest_number = f.arrest_number
where d.address_id is null or a.arrest_number is null or f.address_id is distinct from a.address_id
