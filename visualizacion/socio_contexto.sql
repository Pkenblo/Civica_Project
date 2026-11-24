WITH contexto AS (
    -- El contexto ACS es fijo. Un CP con eventos en otro año también puede tener cero en el año elegido.
    SELECT * FROM DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC
    WHERE has_postal_reference AND cp IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cp ORDER BY arrest_number) = 1
)
SELECT p.cp, TO_JSON(ST_ASGEOJSON(p.geography)) AS geometry, p.boundary_version,
       c.zcta_name, COALESCE(c.has_socioeconomic_data,FALSE) AS has_socioeconomic_data,
       c.acs_year, c.acs_period, c.median_household_income, c.income_margin_of_error,
       c.population, c.median_home_value, c.median_monthly_rent,
       c.income_top_coded, c.home_value_top_coded, c.rent_top_coded,
       c.income_lower_bound, c.home_value_lower_bound, c.rent_lower_bound
FROM DEV_GOLD.GOLD.dim_postal_codes p
LEFT JOIN contexto c ON c.cp = p.cp
