-- Ranking de delitos del último año con expediciones en la fuente.
select cp, year, total_crimes,
       dense_rank() over (order by total_crimes desc) as crime_rank
from {{ ref('mart_cp_crimes_pets') }}
where year = (select max(year) from {{ ref('mart_cp_crimes_pets') }} where has_license_records)
  and has_crime_records
order by crime_rank, cp;

-- Ranking de licencias del mismo año. Puede incluir CP sin polígono local.
select cp, year, total_licenses_issued, dog_licenses_issued, cat_licenses_issued,
       dense_rank() over (order by total_licenses_issued desc) as license_rank
from {{ ref('mart_cp_crimes_pets') }}
where year = (select max(year) from {{ ref('mart_cp_crimes_pets') }} where has_license_records)
  and has_license_records
order by license_rank, cp;

-- Comparación territorial y desglose por gravedad; 2025 es un ejemplo, cámbialo según cobertura.
select cp, year, total_crimes, total_licenses_issued, dog_licenses_issued, cat_licenses_issued,
       serious_crimes, minor_crimes, unclassified_crimes, pct_severity_coverage,
       pct_serious_of_classified, pct_minor_of_classified, crimes_per_1000_licenses_issued
from {{ ref('mart_cp_crimes_pets_severity') }}
where year = 2025 and has_geography
order by cp;

-- Evolución anual: porcentajes recalculados desde sumas, no desde promedios por CP.
select year, count(*) as postal_codes, sum(total_crimes) as total_crimes,
       sum(total_licenses_issued) as total_licenses_issued,
       sum(dog_licenses_issued) as dog_licenses_issued, sum(cat_licenses_issued) as cat_licenses_issued,
       sum(serious_crimes) as serious_crimes, sum(minor_crimes) as minor_crimes,
       sum(unclassified_crimes) as unclassified_crimes,
       100.0 * sum(serious_crimes + minor_crimes) / nullif(sum(total_crimes), 0) as pct_severity_coverage
from {{ ref('mart_cp_crimes_pets_severity') }}
group by year order by year;

-- Pearson por año para CP con polígono y registros de ambas fuentes.
-- Reporta N; exige al menos tres pares y variación no nula. No es inferencia causal.
select year, count(*) as postal_codes,
       corr(total_crimes, total_licenses_issued) as corr_crimes_licenses,
       corr(total_crimes, dog_licenses_issued) as corr_crimes_dog_licenses,
       corr(total_crimes, cat_licenses_issued) as corr_crimes_cat_licenses,
       corr(serious_crimes, total_licenses_issued) as corr_serious_licenses,
       corr(minor_crimes, total_licenses_issued) as corr_minor_licenses
from {{ ref('mart_cp_crimes_pets_severity') }}
where has_geography and has_crime_records and has_license_records
group by year
having count(*) >= 3 and min(total_crimes) < max(total_crimes)
    and min(total_licenses_issued) < max(total_licenses_issued)
order by year;
