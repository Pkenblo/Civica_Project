select c.crime_id, c.offense_date,
       o.offense_category, o.offense_sub_category,
       n.offense_code as nibrs_code, n.offense_description as nibrs_description,
       a.block_address, a.neighborhood, a.cp, a.latitude, a.longitude,
       st_makepoint(a.longitude, a.latitude) as point_geography
from {{ ref('fact_crimes') }} c
join {{ ref('dim_address') }} a on a.address_id = c.address_id
left join {{ ref('dim_offense_classification') }} o
    on o.offense_classification_id = c.offense_classification_id
left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
where a.block_address is not null
  and not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
  and a.latitude between -90 and 90 and a.longitude between -180 and 180
