-- El destino de MERGE debe conservar exactamente una fila por detención.
select arrest_number, count(*) as n_rows
from {{ ref('arrest') }}
group by arrest_number
having arrest_number is null or count(*) <> 1
