select
    agent_key,
    officer_id,
    officer_gender,
    officer_race
from {{ ref('agents') }}