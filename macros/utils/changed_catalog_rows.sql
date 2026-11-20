{% macro changed_catalog_rows(candidates) %}
{% set key = config.get('unique_key') %}
select * from {{ candidates }}
{% if is_incremental() %}
where {{ key }} in (
    select {{ key }}
    from (
        select * from {{ candidates }}
        minus
        select * from {{ this }}
    ) as differences
)
{% endif %}
{% endmacro %}
