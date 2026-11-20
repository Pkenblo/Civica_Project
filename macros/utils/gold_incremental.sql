{% macro gold_changed_rows() -%}
select * from current_rows
{% if is_incremental() %}
except select * from {{ this }}
{% endif %}
{%- endmacro %}

{% macro gold_prune_missing_keys(source_relation, key) -%}
delete from {{ this }}
where not exists (
    select 1 from {{ source_relation }} as source_row
    where source_row.{{ key }} = {{ this.identifier }}.{{ key }}
)
{%- endmacro %}
