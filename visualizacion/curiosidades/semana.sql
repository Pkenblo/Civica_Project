WITH periodo AS (
    SELECT a.arrest_number, d.is_weekend
    FROM DEV_GOLD.GOLD.FACT_ARRESTS a
    LEFT JOIN DEV_GOLD.GOLD.DIM_DATE d ON d.full_date = CAST(a.arrest_occurred_date_time AS DATE)
    WHERE a.arrest_occurred_date_time >= TO_DATE(%s) AND a.arrest_occurred_date_time < TO_DATE(%s)
), sin_fecha AS (
    SELECT COUNT(DISTINCT arrest_number) AS undated_arrests
    FROM DEV_GOLD.GOLD.FACT_ARRESTS WHERE arrest_occurred_date_time IS NULL
)
SELECT COUNT(DISTINCT CASE WHEN p.is_weekend = FALSE THEN p.arrest_number END) AS weekday_count,
       COUNT(DISTINCT CASE WHEN p.is_weekend = TRUE THEN p.arrest_number END) AS weekend_count,
       COUNT(DISTINCT CASE WHEN p.is_weekend IS NULL THEN p.arrest_number END) AS unclassified_arrests,
       (SELECT undated_arrests FROM sin_fecha) AS undated_arrests
FROM periodo p
