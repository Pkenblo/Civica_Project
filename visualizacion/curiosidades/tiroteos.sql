-- La coincidencia de informe NO prueba un vínculo delito-detención ni posterioridad.
-- EXISTS evita multiplicar delitos por etiquetas o detenciones del mismo informe.
WITH periodo AS (
    SELECT c.crime_id, c.report_id
    FROM DEV_GOLD.GOLD.FACT_CRIMES c
    WHERE c.offense_date_time >= TO_DATE(%s) AND c.offense_date_time < TO_DATE(%s)
      AND EXISTS (
          SELECT 1 FROM DEV_GOLD.GOLD.BRIDGE_CRIME_SHOOTING_TYPES b
          JOIN DEV_GOLD.GOLD.DIM_SHOOTING_TYPE t ON t.shooting_type_id = b.shooting_type_id
          WHERE b.crime_id = c.crime_id AND NULLIF(TRIM(t.description), '') IS NOT NULL
      )
)
SELECT (SELECT COUNT(DISTINCT crime_id) FROM periodo) AS shooting_count,
       (SELECT COUNT(DISTINCT p.crime_id) FROM periodo p WHERE EXISTS (
           SELECT 1 FROM DEV_GOLD.GOLD.FACT_ARRESTS a WHERE a.report_id = p.report_id
       )) AS with_arrest,
       (SELECT COUNT(DISTINCT crime_id) FROM periodo WHERE report_id IS NULL) AS missing_report
