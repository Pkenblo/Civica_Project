-- La huella utiliza valores numéricos ya normalizados en staging; no redondea como texto.
-- arrest_number, datos de carga, flags derivados e infracciones no suman completitud.
{% macro arrest_scored_versions(relation) %}

with arrest_normalized as (

    select staging.* replace (
        {% for column in arrest_location_columns() %}
        case when is_location_redacted
            {% if column in ['latitude', 'longitude'] %}or has_invalid_coordinates{% endif %}
            then null else {{ column }} end as {{ column }}{{ ',' if not loop.last }}
        {% endfor %}
    )
    from {{ relation }} as staging
    where arrest_number is not null
      and to_number(case when ingested_at is null
          then 'Fecha de ingesta ausente: ' || arrest_number else '1' end) = 1

)

select
      arrest_normalized.*
    , (
        {% for column in arrest_business_columns() %}
        iff({{ column }} is not null, 1, 0){{ ' + ' if not loop.last }}
        {% endfor %}
      ) as _completeness_score
    , sha2(to_json(array_construct(
        {% for column in arrest_business_columns() + ['is_location_redacted', 'has_invalid_coordinates'] %}
        coalesce(to_variant({{ column }}), parse_json('null')){{ ',' if not loop.last }}
        {% endfor %}
      )), 256) as _row_fingerprint
from arrest_normalized

{% endmacro %}

-- Identidad de una versión de RAW: contenido normalizado e instante de ingesta.
{% macro arrest_version_fingerprint() %}
    sha2(to_json(array_construct(
        _row_fingerprint, convert_timezone('UTC', ingested_at)::timestamp_ntz
    )), 256)
{% endmacro %}
