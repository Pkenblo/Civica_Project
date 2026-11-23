-- Compara la versión publicada, no versiones históricas de un evento ya actualizado.
select 'crime' as source, c.crime_id as event_id
from {{ ref('crimes') }} c
where not exists (
    select 1 from {{ ref('stg_crimes') }} s
    where {{ dbt_utils.generate_surrogate_key(['s.report_number']) }} = c.report_id and s.offense_id = c.offense_id
      and s.ingested_at = c.ingested_at and c.address_id = {{ address_id('s') }}
)
union all
select 'arrest', a.arrest_number
from {{ ref('arrest') }} a
where not exists (
    select 1 from {{ ref('stg_arrests') }} s
    where s.arrest_number = a.arrest_number and s.ingested_at = a.ingested_at
      and a.address_id = {{ address_id('s') }}
)
