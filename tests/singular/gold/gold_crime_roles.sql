select c.crime_id
from {{ ref('fact_crimes') }} c
join {{ ref('crimes') }} s on s.crime_id = c.crime_id
left join {{ ref('dim_report') }} r on r.report_id = c.report_id
where c.offense_date_time is distinct from s.offense_date
   or c.report_date_time is distinct from r.report_date_time
   or c.offense_classification_id is distinct from s.offense_category_id
