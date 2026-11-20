-- Cada detención de staging debe estar publicada con su última fecha de ingesta.
with expected as (
    select arrest_number, max(ingested_at) as last_ingested_at
    from {{ ref('stg_arrests') }}
    where arrest_number is not null
    group by arrest_number
)

select expected.arrest_number
from expected
left join {{ ref('arrest') }} as actual using (arrest_number)
where actual.arrest_number is null
   or actual.last_ingested_at is distinct from expected.last_ingested_at
