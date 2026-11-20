select c.crime_id
from {{ ref('fact_crimes') }} c
join {{ ref('crimes') }} s on s.crime_id = c.crime_id
left join {{ ref('dim_report') }} r on r.report_id = c.report_id
left join {{ ref('dim_offense_subcategory') }} o on o.offense_subcategory_id = c.offense_subcategory_id
where c.offense_date_time is distinct from s.offense_date
   or c.report_date_time is distinct from r.report_date_time
   or (o.offense_subcategory_id is not null and o.offense_category_id is distinct from c.offense_category_id)
