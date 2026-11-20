select subject_key, sk_person, subject_gender, subject_race, ingested_at
from {{ ref('subject') }}
