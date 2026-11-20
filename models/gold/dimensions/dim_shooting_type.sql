{{ config(unique_key='shooting_type_id', post_hook="{{ gold_prune_missing_keys(ref('shooting_types'), 'shooting_type_id') }}") }}

with current_rows as (
    select shooting_type_id, description
    from {{ ref('shooting_types') }}
)
{{ gold_changed_rows() }}
