-- La combinación referenciada debe existir en una observación de la versión publicada.
select c.crime_id
from {{ ref('crimes') }} c
left join {{ ref('offense_categories') }} o using (offense_category_id)
where not exists (
    select 1
    from {{ ref('stg_crimes') }} s
    join {{ ref('reports') }} r on r.report_number = s.report_number
    where r.report_id = c.report_id
      and s.offense_id = c.offense_id
      and s.ingested_at = c.ingested_at
      and equal_null(o.offense_category, s.offense_category)
      and equal_null(o.offense_sub_category, s.offense_sub_category)
      and (c.offense_category_id is null) = (s.offense_category is null and s.offense_sub_category is null)
)
