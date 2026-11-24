{{ config(
    fail_calc='coalesce(max(failure_level), 0)',
    error_if='= 2',
    warn_if='= 1'
) }}

with expected_events as (
    select 'mart_crimes_socioeconomic' as mart_name, c.crime_id::varchar as record_key,
           c.ingested_at
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    -- El mapa excluye ubicaciones no publicables, pero no exige CP ni datos ACS.
    where a.block_address is not null
        and not (a.is_location_redacted or a.has_missing_coordinates or a.has_invalid_coordinates)
        and a.latitude between -90 and 90
        and a.longitude between -180 and 180

    union all
    select 'mart_arrest_socioeconomic', arrest_number::varchar, ingested_at
    from {{ ref('fact_arrests') }}
),

published_events as (
    select 'mart_crimes_socioeconomic' as mart_name, crime_id::varchar as record_key, ingested_at
    from {{ ref('mart_crimes_socioeconomic') }}

    union all
    select 'mart_arrest_socioeconomic', arrest_number::varchar, ingested_at
    from {{ ref('mart_arrest_socioeconomic') }}
),

event_cutoffs as (
    select mart_name, max(ingested_at) as watermark
    from published_events
    group by mart_name
),

event_failures as (
    select coalesce(e.mart_name, p.mart_name) as mart_name,
           coalesce(e.record_key, p.record_key) as record_key,
           cast(null as integer) as year,
           case
               when p.mart_name is null then 'missing_event'
               when e.mart_name is null then 'unexpected_event'
               else 'ingestion_mismatch'
           end as issue,
           e.ingested_at as expected_ingested_at, p.ingested_at as published_ingested_at,
           c.watermark,
           case
               -- Como en silver_gold_coverage, una brecha antigua puede ser una llegada tardía.
               when e.ingested_at <= c.watermark
                   and (p.ingested_at is null or p.ingested_at < e.ingested_at) then 1
               else 2
           end as failure_level
    from expected_events e
    full outer join published_events p on p.mart_name = e.mart_name and p.record_key = e.record_key
    left join event_cutoffs c on c.mart_name = coalesce(e.mart_name, p.mart_name)
    where p.mart_name is null or e.mart_name is null or e.ingested_at is distinct from p.ingested_at
),

dated_crimes as (
    select c.crime_id, c.address_id, c.nibrs_key, d.year
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_date') }} d on d.date_key = c.offense_date_key
),

dated_licenses as (
    select cp, species, year(license_issue_date) as year
    from {{ ref('dim_licenses') }}
    where license_issue_date is not null
),

common_years as (
    -- La cobertura se define antes de filtrar por CP, código NIBRS o especie.
    select year from dated_crimes
    intersect
    select year from dated_licenses
),

crime_counts as (
    select a.cp, c.year,
           count(distinct iff(n.offense_code = '240', c.crime_id, null)) as vehicle_theft_count,
           count(distinct iff(n.offense_code in ('120', '23A', '23B', '23H'), c.crime_id, null)) as theft_count,
           count(distinct iff(s.crime_id is not null or n.offense_code in ('09A', '09B', '09C'),
                              c.crime_id, null)) as shooting_or_homicide_count
    from dated_crimes c
    join common_years y on y.year = c.year
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    left join {{ ref('bridge_crime_shooting_types') }} s on s.crime_id = c.crime_id
    where a.cp is not null
    group by a.cp, c.year
),

license_counts as (
    select l.cp, l.year,
           count(iff(l.species = 'DOG', 1, null)) as dog_license_count,
           count(iff(l.species = 'CAT', 1, null)) as cat_license_count,
           count(iff(l.species = 'GOAT', 1, null)) as goat_license_count,
           count(iff(l.species = 'PIG', 1, null)) as pig_license_count,
           count(*) as pet_license_count
    from dated_licenses l
    join common_years y on y.year = l.year
    where l.cp is not null and l.species in ('DOG', 'CAT', 'GOAT', 'PIG')
    group by l.cp, l.year
),

expected_postal_years as (
    select p.cp, y.year,
           coalesce(c.vehicle_theft_count, 0) as vehicle_theft_count,
           coalesce(c.theft_count, 0) as theft_count,
           coalesce(c.shooting_or_homicide_count, 0) as shooting_or_homicide_count,
           coalesce(l.dog_license_count, 0) as dog_license_count,
           coalesce(l.cat_license_count, 0) as cat_license_count,
           coalesce(l.goat_license_count, 0) as goat_license_count,
           coalesce(l.pig_license_count, 0) as pig_license_count,
           coalesce(l.pet_license_count, 0) as pet_license_count
    from {{ ref('dim_postal_codes') }} p
    cross join common_years y
    left join crime_counts c on c.cp = p.cp and c.year = y.year
    left join license_counts l on l.cp = p.cp and l.year = y.year
),

published_postal_years as (
    select cp, year, vehicle_theft_count, theft_count, shooting_or_homicide_count,
           dog_license_count, cat_license_count, goat_license_count, pig_license_count, pet_license_count,
           count(*) over (partition by cp, year) as rows_per_key
    from {{ ref('mart_crimes_pet_licenses') }}
),

postal_year_checks as (
    select coalesce(e.cp, p.cp)::varchar as record_key, coalesce(e.year, p.year) as year,
           case
               when p.rows_per_key is null then 'missing_postal_year'
               when e.cp is null then 'unexpected_postal_year'
               when p.rows_per_key > 1 then 'duplicate_postal_year'
               when e.vehicle_theft_count is distinct from p.vehicle_theft_count
                   or e.theft_count is distinct from p.theft_count
                   or e.shooting_or_homicide_count is distinct from p.shooting_or_homicide_count
                   then 'crime_counts_mismatch'
               when e.dog_license_count is distinct from p.dog_license_count
                   or e.cat_license_count is distinct from p.cat_license_count
                   or e.goat_license_count is distinct from p.goat_license_count
                   or e.pig_license_count is distinct from p.pig_license_count
                   or e.pet_license_count is distinct from p.pet_license_count
                   then 'license_counts_mismatch'
           end as issue
    from expected_postal_years e
    full outer join published_postal_years p on p.cp = e.cp and p.year = e.year
)

select mart_name, record_key, year, issue, expected_ingested_at, published_ingested_at, watermark, failure_level
from event_failures

union all
-- La vista agregada no aplica cortes de ingesta: cualquier discrepancia es un error.
select 'mart_crimes_pet_licenses', record_key, year, issue, null, null, null, 2
from postal_year_checks
where issue is not null
