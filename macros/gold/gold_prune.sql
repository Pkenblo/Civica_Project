{% macro gold_prune(source_relation, key) -%}
{% if env_var('DBT_GOLD_PRUNE_MISSING_KEYS', '0') == '1' %}
delete from {{ this }}
where not exists (
    select 1 from {{ source_relation }} as source_row
    where source_row.{{ key }} = {{ this.identifier }}.{{ key }}
)
{% endif %}
{%- endmacro %}
