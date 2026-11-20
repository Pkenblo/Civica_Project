{{ config(unique_key='report_id', post_hook="{{ gold_prune_missing_keys(ref('reports'), 'report_id') }}") }}

with current_rows as (
    select report_id, report_number, report_date_time
    from {{ ref('reports') }}
)
{{ gold_changed_rows() }}
