{{ config(unique_key='cp', post_hook="{{ gold_prune_missing_keys(ref('postal_codes'), 'cp') }}") }}

select p.cp, p.geography, p.boundary_version
from {{ ref('postal_codes') }} p
{% if is_incremental() %}
left join {{ this }} t on t.cp = p.cp
where t.cp is null
    or p.boundary_version is distinct from t.boundary_version
    or st_aswkb(p.geography) is distinct from st_aswkb(t.geography)
{% endif %}
