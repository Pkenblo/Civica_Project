{% macro after_max_ingested_at(column, target_column='ingested_at') -%}
    {{ column }} > (select max(t.{{ target_column }}) from {{ this }} as t)
{%- endmacro %}
