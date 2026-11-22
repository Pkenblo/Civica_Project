select c.crime_id, c.offense_date,
       o.offense_category, o.offense_sub_category,
       n.offense_code as nibrs_code, n.offense_description as nibrs_description,
       case
           when n.offense_code in ('09A', '09B', '13A', '13B', '13C', '100') then 'Violencia y agresiones'
           when n.offense_code in ('120', '23A', '23B') then 'Robos y hurtos a personas'
           when n.offense_code in ('11A', '11B', '11C', '11D', '36A', '36B', '90H', '370') then 'Delitos sexuales'
           when n.offense_code in ('23C', '23D', '23E', '23H') then 'Hurtos generales'
           when n.offense_code in ('240', '23F', '23G') then 'Delitos contra vehículos'
           when n.offense_code in ('220', '90J') then 'Allanamientos y accesos ilegales'
           when n.offense_code in ('200', '290') then 'Vandalismo e incendios'
           when n.offense_code in ('90A', '510', '250', '26A', '26B', '26C', '26D', '26E', '26F', '26G', '270', '210', '280') then 'Fraudes y delitos económicos'
           when n.offense_code in ('35A', '35B') then 'Drogas'
           when n.offense_code = '520' then 'Armas'
           when n.offense_code in ('40A', '40B', '40C', '64A', '64B') then 'Prostitución y trata'
           when n.offense_code in ('90B', '90C', '90D', '90E', '90G', '39A', '39B', '39C') then 'Orden público, alcohol y juego'
           when n.offense_code in ('90F', '500') then 'Convivencia y órdenes de protección'
           when n.offense_code = '720' then 'Maltrato animal'
           when n.offense_code in ('09C', '90I', '90Z', '999') then 'Otros y registros especiales'
           else 'Sin clasificar'
       end as nibrs_category,
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
