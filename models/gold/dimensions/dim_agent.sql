{{ config(unique_key='agent_key', post_hook="{{ gold_prune_missing_keys(ref('agents'), 'agent_key') }}") }}

with current_rows as (
    select agent_key, officer_id, officer_gender, officer_race, squad_description, officer_title, ingested_at
    from {{ ref('agents') }}
)
{{ gold_changed_rows() }}
