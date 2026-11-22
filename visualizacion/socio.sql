SELECT latitude, longitude, cp, block_address, neighborhood,
       SUM(arrest_count) AS arrest_count
FROM DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC
WHERE year = %s AND point_geography IS NOT NULL
GROUP BY 1,2,3,4,5
