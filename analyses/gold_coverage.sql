-- Recuento de CP y geometría, incluyendo CP sin polígono registrados solo por licencias.
with license_codes as (select distinct cp from {{ ref('dim_licenses') }} where cp is not null)
select count(*) as postal_codes, coalesce(count_if(p.geography is not null), 0) as mapped_postal_codes,
       coalesce(count_if(p.geography is null), 0) as postal_codes_without_geography,
       coalesce(count_if(p.geography is null and l.cp is not null), 0) as license_codes_without_geography
from {{ ref('dim_postal_codes') }} p
left join license_codes l on l.cp = p.cp;

-- Cobertura de ubicación y tiempo en delitos. El año NULL conserva eventos sin fecha.
select year(c.offense_date_time) as year, coalesce(a.cp_status, 'sin_direccion') as cp_status,
       count(*) as crimes, coalesce(count_if(a.cp is not null and c.offense_date_key is not null), 0) as crimes_in_mart
from {{ ref('fact_crimes') }} c
left join {{ ref('dim_address') }} a on a.address_id = c.address_id
group by 1, 2 order by 1, 2;

-- Cobertura de licencias por año de expedición, sin interpretar estas filas como licencias activas.
select year(license_issue_date) as year, count(*) as licenses,
       coalesce(count_if(cp is not null and license_issue_date_key is not null), 0) as licenses_in_mart,
       coalesce(count_if(cp is null), 0) as missing_cp
from {{ ref('dim_licenses') }}
group by 1 order by 1;

-- Códigos NIBRS pendientes y volumen, con los delitos cuyo código no se informó por separado.
select n.offense_code, n.offense_description, count(*) as total_crimes,
       coalesce(count_if(a.cp is not null and c.offense_date_key is not null), 0) as crimes_in_mart
from {{ ref('fact_crimes') }} c
left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
left join {{ ref('dim_address') }} a on a.address_id = c.address_id
where coalesce(n.severity, 'sin_clasificar') = 'sin_clasificar'
group by 1, 2 order by total_crimes desc;
