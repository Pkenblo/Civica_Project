{% macro gold_changed_rows(by_ingestion=false) -%}
select * from current_rows
{% if is_incremental() %}
{% if by_ingestion %}
where {{ after_max_ingested_at('ingested_at') }}
{% else %}
except select * from {{ this }}
{% endif %}
{% endif %}
{%- endmacro %}

{% macro gold_prune_missing_keys(source_relation, key) -%}
delete from {{ this }}
where not exists (
    select 1 from {{ source_relation }} as source_row
    where source_row.{{ key }} = {{ this.identifier }}.{{ key }}
)
{%- endmacro %}
