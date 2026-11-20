{{ config(unique_key='arrest_type_id', post_hook="{{ gold_prune_missing_keys(ref('arrest_types'), 'arrest_type_id') }}") }}

with current_rows as (
    select arrest_type_id, description
    from {{ ref('arrest_types') }}
)
{{ gold_changed_rows() }}
