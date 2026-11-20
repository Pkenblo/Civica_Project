{{ config(unique_key='nibrs_key', post_hook="{{ gold_prune_missing_keys(ref('nibrs'), 'nibrs_key') }}") }}

with current_rows as (
select n.nibrs_key, n.offense_code, n.offense_description, n.group_ab, n.crime_against_category,
       coalesce(m.severity, 'sin_clasificar') as severity,
       m.rationale as severity_rationale
from {{ ref('nibrs') }} n
left join {{ ref('nibrs_severity_map') }} m on m.offense_code = n.offense_code
)
{{ gold_changed_rows() }}
