WITH periodo AS (
    SELECT a.arrest_number, NULLIF(TRIM(d.officer_id), '') AS officer_id
    FROM DEV_GOLD.GOLD.FACT_ARRESTS a
    LEFT JOIN DEV_GOLD.GOLD.DIM_AGENT d ON d.agent_key = a.agent_key
    WHERE a.arrest_occurred_date_time >= TO_DATE(%s) AND a.arrest_occurred_date_time < TO_DATE(%s)
), recuentos AS (
    SELECT officer_id, COUNT(DISTINCT arrest_number) AS arrest_count
    FROM periodo WHERE officer_id IS NOT NULL GROUP BY officer_id
), ranking AS (
    SELECT *, DENSE_RANK() OVER (ORDER BY arrest_count DESC) AS position
    FROM recuentos
), cobertura AS (
    SELECT COUNT(DISTINCT arrest_number) AS total_arrests,
           COUNT(DISTINCT CASE WHEN officer_id IS NULL THEN arrest_number END) AS unidentified_arrests
    FROM periodo
)
SELECT r.officer_id, COALESCE(r.arrest_count, 0) AS arrest_count,
       c.total_arrests, c.unidentified_arrests
FROM cobertura c LEFT JOIN ranking r ON r.position = 1
ORDER BY r.officer_id
