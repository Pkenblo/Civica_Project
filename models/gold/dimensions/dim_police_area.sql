{{ config(unique_key='police_area_id', post_hook="{{ gold_prune_missing_keys(ref('police_add'), 'police_area_id') }}") }}

with current_rows as (
    select police_area_id, precinct, sector, beat
    from {{ ref('police_add') }}
)
{{ gold_changed_rows() }}
