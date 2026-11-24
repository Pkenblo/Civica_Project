{# Staging valida el par RAW antes de redondear: un par inválido no se recupera aquí. #}
{% macro address_coordinate(location, coordinate) -%}
    {%- set limit = 90 if coordinate == 'latitude' else 180 -%}
    case when not coalesce({{ location }}.has_invalid_coordinates, false)
              and {{ location }}.{{ coordinate }} between -{{ limit }} and {{ limit }}
         then {{ location }}.{{ coordinate }} end
{%- endmacro %}

{% macro address_id(location) -%}
    {# Solo geografía: ni evento, ni calidad, ni CP forman parte de la identidad. #}
    {%- set latitude = address_coordinate(location, 'latitude') -%}
    {%- set longitude = address_coordinate(location, 'longitude') -%}
    case when coalesce({{ location }}.is_location_redacted, false) then 'REDACTED'
         when {{ location }}.block_address is null and {{ latitude }} is null and {{ longitude }} is null
              and {{ location }}.neighborhood is null and {{ location }}.reporting_area is null
              and {{ location }}.census_block_2020 is null then 'UNKNOWN'
         else {{ dbt_utils.generate_surrogate_key([
             location ~ '.block_address', latitude, longitude,
             location ~ '.neighborhood', location ~ '.reporting_area', location ~ '.census_block_2020'
         ]) }} end
{%- endmacro %}
