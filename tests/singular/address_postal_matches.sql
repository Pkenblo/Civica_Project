-- Contrasta el CP con el mapa sin cambiar las reglas del modelo.
with points as (
    select address_id, cp, cp_status, st_makepoint(longitude, latitude) as point
    from {{ ref('full_address') }}
    where not coalesce(is_location_redacted, false)
      and latitude between -90 and 90 and longitude between -180 and 180
),
expected as (
    select p.address_id, p.cp, p.cp_status, count(z.cp) as covered, min(z.cp) as candidate_cp,
           count_if(st_contains(z.geography, p.point)) as interiors
    from points p
    left join {{ ref('postal_codes') }} z on st_covers(z.geography, p.point)
    group by p.address_id, p.cp, p.cp_status
)
select address_id
from expected
where cp_status is distinct from case when covered = 0 then 'no_match'
                                     when covered > 1 then 'ambiguous'
                                     when coalesce(interiors, 0) = 0 then 'boundary'
                                     else 'matched' end
   or cp is distinct from iff(covered = 1 and interiors > 0, candidate_cp, null)
