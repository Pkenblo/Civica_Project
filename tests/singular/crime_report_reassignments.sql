{{ config(severity='warn') }}
-- Señal para revisión: compartir offense_id no prueba que haya una baja.
select offense_id, count(distinct report_number) as report_count
from {{ ref('stg_crimes') }}
group by offense_id
having count(distinct report_number) > 1
