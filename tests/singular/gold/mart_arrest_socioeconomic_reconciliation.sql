with expected as (
    -- Todas las detenciones, sin filtros de CP, fecha o localización.
    select arrest_number, count(*) as row_count
    from {{ ref('fact_arrests') }}
    group by arrest_number
),

actual as (
    select arrest_number, count(*) as row_count, sum(arrest_count) as arrest_count
    from {{ ref('mart_arrest_socioeconomic') }}
    group by arrest_number
)

select coalesce(e.arrest_number, a.arrest_number) as arrest_number,
       e.row_count as source_rows, a.row_count as mart_rows
from expected e
full outer join actual a on a.arrest_number = e.arrest_number
where e.row_count is distinct from a.row_count
   or a.row_count is distinct from 1
   or a.arrest_count is distinct from 1
