-- Comprueba los valores consolidados que se almacenan, no solo las comparaciones de staging.
select arrest_number
from {{ ref('arrest') }}
where consolidation_choices:latitude::number(18, 12)
        <> round(consolidation_choices:latitude::number(18, 12), 5)
   or consolidation_choices:longitude::number(18, 12)
        <> round(consolidation_choices:longitude::number(18, 12), 5)
