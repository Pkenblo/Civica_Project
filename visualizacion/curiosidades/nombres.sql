-- Una licencia conservada en Gold no equivale necesariamente a un animal único.
WITH periodo AS (
    SELECT license_number, species, NULLIF(TRIM(animal_name), '') AS animal_name
    FROM DEV_GOLD.GOLD.DIM_LICENSES
    WHERE license_issue_date >= TO_DATE(%s) AND license_issue_date < TO_DATE(%s)
      AND species IN ('DOG', 'CAT')
), recuentos AS (
    SELECT species, animal_name, COUNT(DISTINCT license_number) AS license_count
    FROM periodo WHERE animal_name IS NOT NULL
    GROUP BY species, animal_name
), ranking AS (
    SELECT *, DENSE_RANK() OVER (PARTITION BY species ORDER BY license_count DESC) AS position
    FROM recuentos
), cobertura AS (
    SELECT species, COUNT(DISTINCT license_number) AS total_licenses,
           COUNT(DISTINCT CASE WHEN animal_name IS NULL THEN license_number END) AS unnamed_licenses
    FROM periodo GROUP BY species
), sin_fecha AS (
    SELECT species, COUNT(DISTINCT license_number) AS undated_licenses
    FROM DEV_GOLD.GOLD.DIM_LICENSES
    WHERE license_issue_date IS NULL GROUP BY species
), especies AS (
    SELECT 'DOG' AS species UNION ALL SELECT 'CAT'
)
SELECT e.species, r.animal_name, COALESCE(r.license_count, 0) AS license_count,
       COALESCE(c.total_licenses, 0) AS total_licenses,
       COALESCE(c.unnamed_licenses, 0) AS unnamed_licenses,
       COALESCE(f.undated_licenses, 0) AS undated_licenses
FROM especies e
LEFT JOIN ranking r ON r.species = e.species AND r.position = 1
LEFT JOIN cobertura c ON c.species = e.species
LEFT JOIN sin_fecha f ON f.species = e.species
ORDER BY e.species, r.animal_name
