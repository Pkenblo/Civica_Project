select nibrs_key, offense_code, offense_description, group_ab, crime_against_category,
       case
           when offense_code in ('09A', '09B', '13A', '13B', '13C', '100') then 'Violencia y agresiones'
           when offense_code in ('120', '23A', '23B') then 'Robos y hurtos a personas'
           when offense_code in ('11A', '11B', '11C', '11D', '36A', '36B', '90H', '370') then 'Delitos sexuales'
           when offense_code in ('23C', '23D', '23E', '23H') then 'Hurtos generales'
           when offense_code in ('240', '23F', '23G') then 'Delitos contra vehículos'
           when offense_code in ('220', '90J') then 'Allanamientos y accesos ilegales'
           when offense_code in ('200', '290') then 'Vandalismo e incendios'
           when offense_code in ('90A', '510', '250', '26A', '26B', '26C', '26D', '26E', '26F', '26G', '270', '210', '280') then 'Fraudes y delitos económicos'
           when offense_code in ('35A', '35B') then 'Drogas'
           when offense_code = '520' then 'Armas'
           when offense_code in ('40A', '40B', '40C', '64A', '64B') then 'Prostitución y trata'
           when offense_code in ('90B', '90C', '90D', '90E', '90G', '39A', '39B', '39C') then 'Orden público, alcohol y juego'
           when offense_code in ('90F', '500') then 'Convivencia y órdenes de protección'
           when offense_code = '720' then 'Maltrato animal'
           when offense_code in ('09C', '90I', '90Z', '999') then 'Otros y registros especiales'
           else 'Sin clasificar'
       end as nibrs_category
from {{ ref('nibrs') }}
