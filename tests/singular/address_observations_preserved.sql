-- Toda observación tiene destino; las parciales conservan los atributos aprovechables.
with observations as (
    select block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_crimes') }}
    union all
    select block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020,
           is_location_redacted, has_missing_coordinates, has_invalid_coordinates
    from {{ ref('stg_arrests') }}
)
select {{ address_id('s') }} as expected_address_id
from observations s
left join {{ ref('full_address') }} d on d.address_id = {{ address_id('s') }}
where d.address_id is null
   or (d.address_id not in ('UNKNOWN', 'REDACTED') and (
       not equal_null(d.block_address, s.block_address)
       or not equal_null(d.latitude, {{ address_coordinate('s', 'latitude') }})
       or not equal_null(d.longitude, {{ address_coordinate('s', 'longitude') }})
       or not equal_null(d.neighborhood, s.neighborhood)
       or not equal_null(d.reporting_area, s.reporting_area)
       or not equal_null(d.census_block_2020, s.census_block_2020)))
