{{ config(unique_key='offense_subcategory_id', post_hook="{{ gold_prune_missing_keys(ref('offense_subcategories'), 'offense_subcategory_id') }}") }}

with current_rows as (
    select offense_subcategory_id, offense_category_id, offense_sub_category
    from {{ ref('offense_subcategories') }}
)
{{ gold_changed_rows() }}
