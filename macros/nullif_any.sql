-- nullif_any.sql
-- Convierte en NULL si el valor coincide con cualquiera de los indicados.

{% macro nullif_any(expression) -%}

    {%- if varargs | length == 0 -%}

        {{ expression }}

    {%- else -%}

        {%- set nullsif -%}

            {%- for value in varargs -%}

                {%- if value is string -%}
                    '{{ value | replace("\\", "\\\\") | replace("'", "''") }}'
                {%- elif value is none -%}
                    null
                {%- else -%}
                    {{ value }}
                {%- endif -%}

                {{- ', ' if not loop.last -}}

            {%- endfor -%}

        {%- endset -%}

        case
            when {{ expression }} in ({{ nullsif }}) then null
            else {{ expression }}
        end

    {%- endif -%}

{%- endmacro %}