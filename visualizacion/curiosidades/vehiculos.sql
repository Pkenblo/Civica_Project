-- block_address identifica un bloque publicado, no una calle normalizada.
WITH periodo AS (
    SELECT c.crime_id,
           CASE WHEN COALESCE(a.is_location_redacted, FALSE) = FALSE
                     AND UPPER(TRIM(a.block_address)) NOT IN ('', '-', 'REDACTED')
                THEN TRIM(a.block_address) END AS block_address
    FROM DEV_GOLD.GOLD.FACT_CRIMES c
    JOIN DEV_GOLD.GOLD.DIM_NIBRS n ON n.nibrs_key = c.nibrs_key
    LEFT JOIN DEV_GOLD.GOLD.DIM_ADDRESS a ON a.address_id = c.address_id
    WHERE c.offense_date_time >= TO_DATE(%s) AND c.offense_date_time < TO_DATE(%s)
      AND n.offense_code = '240'
), recuentos AS (
    SELECT block_address, COUNT(DISTINCT crime_id) AS crime_count
    FROM periodo WHERE block_address IS NOT NULL GROUP BY block_address
), ranking AS (
    SELECT *, DENSE_RANK() OVER (ORDER BY crime_count DESC) AS position
    FROM recuentos
), cobertura AS (
    SELECT COUNT(DISTINCT crime_id) AS total_thefts,
           COUNT(DISTINCT CASE WHEN block_address IS NULL THEN crime_id END) AS excluded_thefts
    FROM periodo
)
SELECT r.block_address, COALESCE(r.crime_count, 0) AS crime_count,
       c.total_thefts, c.excluded_thefts
FROM cobertura c LEFT JOIN ranking r ON r.position = 1
ORDER BY r.block_address
