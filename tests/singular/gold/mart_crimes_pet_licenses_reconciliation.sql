with crime_years as (
    select distinct year(offense_date) as year
    from {{ ref('fact_crimes') }}
    where offense_date is not null
),

license_years as (
    select distinct year(license_issue_date) as year
    from {{ ref('dim_licenses') }}
    where license_issue_date is not null
),

common_years as (
    select year from crime_years
    intersect
    select year from license_years
),

crime_totals as (
    select a.cp, year(c.offense_date) as year,
           count(distinct iff(n.offense_code = '240', c.crime_id, null)) as vehicle_theft_count,
           count(distinct iff(n.offense_code in ('120', '23A', '23B', '23H'), c.crime_id, null)) as theft_count,
           count(distinct iff(s.crime_id is not null or n.offense_code in ('09A', '09B', '09C'),
                              c.crime_id, null)) as shooting_or_homicide_count
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    join common_years y on y.year = year(c.offense_date)
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    left join {{ ref('bridge_crime_shooting_types') }} s on s.crime_id = c.crime_id
    where a.cp is not null
    group by a.cp, year(c.offense_date)
),

license_totals as (
    select cp, year(license_issue_date) as year,
           count(iff(species = 'DOG', 1, null)) as dogs,
           count(iff(species = 'CAT', 1, null)) as cats,
           count(iff(species = 'GOAT', 1, null)) as goats,
           count(iff(species = 'PIG', 1, null)) as pigs
    from {{ ref('dim_licenses') }}
    where cp is not null and license_issue_date is not null
    group by cp, year(license_issue_date)
),

license_history as (
    -- Acumular antes de filtrar a los años comunes: puede haber licencias anteriores sin delitos.
    select p.cp, y.year,
           coalesce(l.dogs, 0) as dog_license_count,
           coalesce(l.cats, 0) as cat_license_count,
           coalesce(l.goats, 0) as goat_license_count,
           coalesce(l.pigs, 0) as pig_license_count,
           sum(coalesce(l.dogs, 0)) over (partition by p.cp order by y.year rows unbounded preceding)
               as cumulative_dog_license_count,
           sum(coalesce(l.cats, 0)) over (partition by p.cp order by y.year rows unbounded preceding)
               as cumulative_cat_license_count,
           sum(coalesce(l.goats, 0)) over (partition by p.cp order by y.year rows unbounded preceding)
               as cumulative_goat_license_count,
           sum(coalesce(l.pigs, 0)) over (partition by p.cp order by y.year rows unbounded preceding)
               as cumulative_pig_license_count
    from {{ ref('dim_postal_codes') }} p
    cross join license_years y
    left join license_totals l on l.cp = p.cp and l.year = y.year
),

expected as (
    select l.cp, l.year,
           coalesce(c.vehicle_theft_count, 0) as vehicle_theft_count,
           coalesce(c.theft_count, 0) as theft_count,
           coalesce(c.shooting_or_homicide_count, 0) as shooting_or_homicide_count,
           l.dog_license_count, l.cat_license_count, l.goat_license_count, l.pig_license_count,
           l.dog_license_count + l.cat_license_count + l.goat_license_count + l.pig_license_count
               as pet_license_count,
           l.cumulative_dog_license_count, l.cumulative_cat_license_count,
           l.cumulative_goat_license_count, l.cumulative_pig_license_count
    from license_history l
    join common_years y on y.year = l.year
    left join crime_totals c on c.cp = l.cp and c.year = l.year
),

actual as (
    select cp, year, vehicle_theft_count, theft_count, shooting_or_homicide_count,
           dog_license_count, cat_license_count, goat_license_count, pig_license_count, pet_license_count,
           cumulative_dog_license_count, cumulative_cat_license_count,
           cumulative_goat_license_count, cumulative_pig_license_count
    from {{ ref('mart_crimes_pet_licenses') }}
),

missing as (
    select * from expected
    except
    select * from actual
),

unexpected as (
    select * from actual
    except
    select * from expected
)

select 'expected' as row_source, * from missing
union all
select 'published' as row_source, * from unexpected
