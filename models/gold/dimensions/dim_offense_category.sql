{{ config(unique_key='offense_category_id', post_hook="{{ gold_prune_missing_keys(ref('offense_categories'), 'offense_category_id') }}") }}

with current_rows as (
    select offense_category_id, offense_category
    from {{ ref('offense_categories') }}
)
{{ gold_changed_rows() }}
