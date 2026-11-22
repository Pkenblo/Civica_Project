WITH seleccion AS (
  SELECT * FROM DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES WHERE year BETWEEN 2024 AND 2026
), mapa AS (
  SELECT cp, geography FROM seleccion WHERE geography IS NOT NULL
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cp ORDER BY year) = 1
), registros AS (
  SELECT ARRAY_CONSTRUCT('comparacion',cp,year,vehicle_theft_count,dog_license_count,
                         cat_license_count,goat_license_count,pig_license_count,theft_count,
                         cumulative_dog_license_count,cumulative_cat_license_count,
                         cumulative_goat_license_count,cumulative_pig_license_count,
                         shooting_or_homicide_count) AS fila
  FROM seleccion
  UNION ALL
  SELECT ARRAY_CONSTRUCT('geo',cp,ST_ASGEOJSON(geography))
  FROM mapa
)
SELECT TO_JSON(fila) FROM registros
