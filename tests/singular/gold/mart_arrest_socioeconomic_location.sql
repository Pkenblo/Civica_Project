select m.arrest_number
from {{ ref('mart_arrest_socioeconomic') }} m
join {{ ref('fact_arrests') }} r on r.arrest_number = m.arrest_number
left join {{ ref('dim_address') }} a on a.address_id = r.address_id
where m.address_id is distinct from r.address_id
   or m.arrest_occurred_date_time is distinct from r.arrest_occurred_date_time
   or m.arrest_occurred_date is distinct from r.arrest_occurred_date
   or m.year is distinct from year(r.arrest_occurred_date)
   or m.has_address_data is distinct from (a.address_id is not null)
   or m.block_address is distinct from a.block_address
   or m.latitude is distinct from a.latitude
   or m.longitude is distinct from a.longitude
   or m.neighborhood is distinct from a.neighborhood
   or m.reporting_area is distinct from a.reporting_area
   or m.census_block_2020 is distinct from a.census_block_2020
   or m.cp is distinct from a.cp
   or m.cp_status is distinct from a.cp_status
   or m.is_location_redacted is distinct from a.is_location_redacted
   or m.has_missing_coordinates is distinct from a.has_missing_coordinates
   or m.has_invalid_coordinates is distinct from a.has_invalid_coordinates
   or st_aswkt(m.point_geography) is distinct from st_aswkt(
       case when not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
                 and a.latitude between -90 and 90 and a.longitude between -180 and 180
            then st_makepoint(a.longitude, a.latitude) end
   )
