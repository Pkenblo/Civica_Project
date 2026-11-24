SELECT cp, YEAR(offense_date) AS year, has_postal_reference,
       COALESCE(nibrs_category,'Sin clasificar') AS nibrs_category,
       nibrs_code, nibrs_description, COUNT(*) AS crime_count
FROM DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC
WHERE offense_date >= TO_DATE('2024-01-01') AND offense_date < TO_DATE('2027-01-01')
GROUP BY 1,2,3,4,5,6
