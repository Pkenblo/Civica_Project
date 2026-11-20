{{ config(unique_key='cad_profile_id', post_hook="{{ gold_prune_missing_keys(ref('cad_profiles'), 'cad_profile_id') }}") }}

with current_rows as (
    select cad_profile_id, cad_clearance, cad_initial_call_type, cad_priority
    from {{ ref('cad_profiles') }}
)
{{ gold_changed_rows() }}
