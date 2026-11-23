{{ config(unique_key='report_id') }}

select report_id, 
       report_number, 
       report_date_time, 
       ingested_at
from {{ ref('reports') }}
{% if is_incremental() %}
where {{ after_max_ingested_at('ingested_at') }}
{% endif %}
