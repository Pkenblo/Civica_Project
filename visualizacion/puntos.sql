SELECT latitude, longitude, COALESCE(nibrs_category,'Sin clasificar'),
       nibrs_code, nibrs_description, COUNT(*), cp, block_address, neighborhood
FROM DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC
WHERE offense_date >= TO_DATE(%s) AND offense_date < DATEADD(month, 1, TO_DATE(%s))
GROUP BY 1,2,3,4,5,7,8,9
