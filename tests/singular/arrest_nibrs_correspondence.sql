-- Un nulo es ausencia, no un error de correspondencia. No se infiere nada desde RCW/SMC.
-- Las descripciones sin correspondencia o ambiguas fallan aunque el cargo se conserve.
with descriptions as (
    select nibrs_description, count(*) as source_rows
    from {{ ref('stg_arrests') }}
    where nibrs_description is not null
    group by nibrs_description
)
select d.nibrs_description, d.source_rows, count(n.nibrs_key) as matching_codes
from descriptions d
left join {{ ref('nibrs') }} n on n.offense_description = d.nibrs_description
group by d.nibrs_description, d.source_rows
having count(n.nibrs_key) <> 1
