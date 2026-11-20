{{ config(unique_key='subject_key', post_hook="{{ gold_prune_missing_keys(ref('subject'), 'subject_key') }}") }}

with current_rows as (
    select subject_key, sk_person, subject_gender, subject_race, ingested_at
    from {{ ref('subject') }}
)
{{ gold_changed_rows() }}
