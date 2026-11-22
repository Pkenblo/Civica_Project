SELECT cp, year, has_postal_reference,
       point_geography IS NOT NULL AS has_point,
       SUM(arrest_count) AS arrest_count
FROM DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC
WHERE year BETWEEN 2024 AND 2026 OR year IS NULL
GROUP BY 1,2,3,4
