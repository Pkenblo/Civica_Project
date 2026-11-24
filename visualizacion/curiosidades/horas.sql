WITH periodo AS (
    SELECT crime_id, EXTRACT(HOUR FROM offense_date_time) AS hour
    FROM DEV_GOLD.GOLD.FACT_CRIMES
    WHERE offense_date_time >= TO_DATE(%s) AND offense_date_time < TO_DATE(%s)
), recuentos AS (
    SELECT hour, COUNT(DISTINCT crime_id) AS crime_count
    FROM periodo GROUP BY hour
), ranking AS (
    SELECT *, DENSE_RANK() OVER (ORDER BY crime_count DESC) AS position
    FROM recuentos
), cobertura AS (
    SELECT COUNT(DISTINCT crime_id) AS total_crimes FROM periodo
), sin_fecha AS (
    SELECT COUNT(DISTINCT crime_id) AS undated_crimes
    FROM DEV_GOLD.GOLD.FACT_CRIMES WHERE offense_date_time IS NULL
)
SELECT r.hour, COALESCE(r.crime_count, 0) AS crime_count, r.position,
       c.total_crimes, f.undated_crimes
FROM cobertura c CROSS JOIN sin_fecha f
LEFT JOIN ranking r ON 1 = 1
ORDER BY r.hour
