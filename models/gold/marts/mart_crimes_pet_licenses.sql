{{ config(materialized='view') }}

with crime_events as (
    select c.crime_id, c.address_id, c.nibrs_key, d.year
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_date') }} d on d.date_key = c.offense_date_key
),

common_years as (
    -- La cobertura se calcula antes de filtrar por delito, CP o especie.
    select year from crime_events
    intersect
    select year(license_issue_date) as year
    from {{ ref('dim_licenses') }}
    where license_issue_date is not null
),

shooting_crimes as (
    -- Varias etiquetas no convierten un delito en varios eventos.
    select distinct crime_id
    from {{ ref('bridge_crime_shooting_types') }}
),

crime_counts as (
    select
          a.cp
        , c.year
        , sum(case when n.offense_code = '240' then 1 else 0 end) as vehicle_theft_count
        , sum(case when n.offense_code in ('120', '23A', '23B', '23H') then 1 else 0 end) as theft_count
        , sum(case
            when s.crime_id is not null or n.offense_code in ('09A', '09B', '09C') then 1
            else 0
          end) as shooting_or_homicide_count
    from crime_events c
    join common_years y on y.year = c.year
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    left join shooting_crimes s on s.crime_id = c.crime_id
    where a.cp is not null
    group by a.cp, c.year
),

license_counts as (
    select
          cp
        , year(license_issue_date) as year
        , sum(case when species = 'DOG' then 1 else 0 end) as dog_license_count
        , sum(case when species = 'CAT' then 1 else 0 end) as cat_license_count
        , sum(case when species = 'GOAT' then 1 else 0 end) as goat_license_count
        , sum(case when species = 'PIG' then 1 else 0 end) as pig_license_count
        , count(*) as pet_license_count
    from {{ ref('dim_licenses') }}
    where cp is not null
        and license_issue_date is not null
        and species in ('DOG', 'CAT', 'GOAT', 'PIG')
    group by cp, year(license_issue_date)
),

postal_years as (
    select p.cp, y.year, p.geography, p.boundary_version
    from {{ ref('dim_postal_codes') }} p
    cross join common_years y
),

licenses_by_cutoff as (
    -- Incluir emisiones anteriores aunque su año no tenga delitos.
    select
          p.cp
        , p.year
        , coalesce(sum(l.dog_license_count), 0) as cumulative_dog_license_count
        , coalesce(sum(l.cat_license_count), 0) as cumulative_cat_license_count
        , coalesce(sum(l.goat_license_count), 0) as cumulative_goat_license_count
        , coalesce(sum(l.pig_license_count), 0) as cumulative_pig_license_count
    from postal_years p
    left join license_counts l on l.cp = p.cp and l.year <= p.year
    group by p.cp, p.year
),

counts as (
    select
          p.cp
        , p.year
        , p.geography
        , p.boundary_version
        , coalesce(c.vehicle_theft_count, 0) as vehicle_theft_count
        , coalesce(c.theft_count, 0) as theft_count
        , coalesce(c.shooting_or_homicide_count, 0) as shooting_or_homicide_count
        , coalesce(l.dog_license_count, 0) as dog_license_count
        , coalesce(l.cat_license_count, 0) as cat_license_count
        , coalesce(l.goat_license_count, 0) as goat_license_count
        , coalesce(l.pig_license_count, 0) as pig_license_count
        , coalesce(l.pet_license_count, 0) as pet_license_count
        , h.cumulative_dog_license_count
        , h.cumulative_cat_license_count
        , h.cumulative_goat_license_count
        , h.cumulative_pig_license_count
    from postal_years p
    left join crime_counts c on c.cp = p.cp and c.year = p.year
    left join license_counts l on l.cp = p.cp and l.year = p.year
    join licenses_by_cutoff h on h.cp = p.cp and h.year = p.year
)

select
      cp
    , year
    , vehicle_theft_count
    , theft_count
    , shooting_or_homicide_count
    , dog_license_count
    , cat_license_count
    , goat_license_count
    , pig_license_count
    , pet_license_count
    , dog_license_count / nullif(pet_license_count, 0) as dog_license_share
    , cat_license_count / nullif(pet_license_count, 0) as cat_license_share
    , goat_license_count / nullif(pet_license_count, 0) as goat_license_share
    , pig_license_count / nullif(pet_license_count, 0) as pig_license_share
    , geography
    , boundary_version
    , cumulative_dog_license_count
    , cumulative_cat_license_count
    , cumulative_goat_license_count
    , cumulative_pig_license_count
from counts
