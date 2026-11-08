-- generate_schema_name.sql
-- Genera el nombre de los schemas para snowflake

{% macro generate_schema_name(custom_schema_name, node) -%}
{%- if custom_schema_name is none -%}
{{ target.schema }}
{%- else -%}
{{ custom_schema_name | trim }}
{%- endif -%}
{%- endmacro %}
