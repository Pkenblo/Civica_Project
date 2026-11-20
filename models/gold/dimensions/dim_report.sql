select report_id, report_number, report_date_time
from {{ ref('reports') }}
