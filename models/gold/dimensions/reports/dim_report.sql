select
      report_id
    , report_number
    , report_date_time
    , ingested_at
from {{ ref('reports') }}
