{% macro after_max_ingested_at(column) -%}
    {{ column }} > (select max(t.ingested_at) from {{ this }} as t)
{%- endmacro %}
