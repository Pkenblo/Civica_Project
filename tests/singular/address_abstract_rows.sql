-- Deben existir ambas filas incluso cuando staging está vacío.
with expected as (
    select 'UNKNOWN' as address_id, false as is_location_redacted
    union all
    select 'REDACTED', true
)
select e.address_id
from expected e
left join {{ ref('full_address') }} d on d.address_id = e.address_id
group by e.address_id, e.is_location_redacted
having count(d.address_id) <> 1
    or count_if(d.block_address is not null or d.latitude is not null or d.longitude is not null
                or d.neighborhood is not null or d.reporting_area is not null
                or d.census_block_2020 is not null or d.cp is not null
                or d.is_location_redacted is distinct from e.is_location_redacted
                or d.has_missing_coordinates is distinct from true
                or d.has_invalid_coordinates is distinct from false
                or d.cp_status is distinct from iff(e.is_location_redacted, 'redacted', 'missing_coordinates')) > 0
