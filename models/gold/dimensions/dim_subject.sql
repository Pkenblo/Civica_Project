{{ config(unique_key='subject_key') }}

select subject_key, 
       sk_person, 
       subject_gender, 
       subject_race, 
       ingested_at
from {{ ref('subject') }}
{% if is_incremental() %}
where {{ after_max_ingested_at('ingested_at') }}
{% endif %}
