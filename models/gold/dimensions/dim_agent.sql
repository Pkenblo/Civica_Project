select agent_key, officer_id, officer_gender, officer_race, squad_description, officer_title, ingested_at
from {{ ref('agents') }}
