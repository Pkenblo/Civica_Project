{{ config(severity='error') }}

{% set crime_counts = [
    'vehicle_theft_count',
    'theft_count',
    'shooting_or_homicide_count'
] %}
{% set license_counts = [
    'dog_license_count',
    'cat_license_count',
    'goat_license_count',
    'pig_license_count',
    'pet_license_count'
] %}
{% set cumulative_counts = [
    'cumulative_dog_license_count',
    'cumulative_cat_license_count',
    'cumulative_goat_license_count',
    'cumulative_pig_license_count'
] %}
{% set count_columns = crime_counts + license_counts + cumulative_counts %}

-- El grano del mart es CP-año, no una fila por delito o licencia.
-- Los tres indicadores de delitos no son conjuntos disjuntos: se validan por separado.
with dated_crimes as (
    select c.crime_id, c.address_id, c.nibrs_key, d.year
    from {{ ref('fact_crimes') }} c
    join {{ ref('dim_date') }} d on d.date_key = c.offense_date_key
),

common_years as (
    -- El ámbito temporal se fija antes de filtrar por CP, especie o tipo de delito.
    select year from dated_crimes
    intersect
    select year(license_issue_date) as year
    from {{ ref('dim_licenses') }}
    where license_issue_date is not null
),

postal_years as (
    select p.cp, y.year
    from {{ ref('dim_postal_codes') }} p
    cross join common_years y
),

expected_crimes as (
    -- DISTINCT impide que varias etiquetas de tiroteo multipliquen un delito.
    select a.cp, c.year,
           count(distinct iff(n.offense_code = '240', c.crime_id, null)) as vehicle_theft_count,
           count(distinct iff(n.offense_code in ('120', '23A', '23B', '23H'),
                              c.crime_id, null)) as theft_count,
           count(distinct iff(n.offense_code in ('09A', '09B', '09C') or s.crime_id is not null,
                              c.crime_id, null)) as shooting_or_homicide_count
    from dated_crimes c
    join common_years y on y.year = c.year
    join {{ ref('dim_address') }} a on a.address_id = c.address_id
    left join {{ ref('dim_nibrs') }} n on n.nibrs_key = c.nibrs_key
    left join {{ ref('bridge_crime_shooting_types') }} s on s.crime_id = c.crime_id
    where a.cp is not null
    group by a.cp, c.year
),

eligible_licenses as (
    select license_number, cp, species, year(license_issue_date) as year
    from {{ ref('dim_licenses') }}
    where cp is not null
        and license_issue_date is not null
        and species in ('DOG', 'CAT', 'GOAT', 'PIG')
),

expected_licenses as (
    select cp, year,
           count(distinct iff(species = 'DOG', license_number, null)) as dog_license_count,
           count(distinct iff(species = 'CAT', license_number, null)) as cat_license_count,
           count(distinct iff(species = 'GOAT', license_number, null)) as goat_license_count,
           count(distinct iff(species = 'PIG', license_number, null)) as pig_license_count,
           count(distinct license_number) as pet_license_count
    from eligible_licenses
    group by cp, year
),

expected_cumulative_licenses as (
    -- Los acumulados incluyen licencias anteriores a los años comunes.
    select p.cp, p.year,
           count(distinct iff(l.species = 'DOG', l.license_number, null)) as cumulative_dog_license_count,
           count(distinct iff(l.species = 'CAT', l.license_number, null)) as cumulative_cat_license_count,
           count(distinct iff(l.species = 'GOAT', l.license_number, null)) as cumulative_goat_license_count,
           count(distinct iff(l.species = 'PIG', l.license_number, null)) as cumulative_pig_license_count
    from postal_years p
    left join eligible_licenses l on l.cp = p.cp and l.year <= p.year
    group by p.cp, p.year
),

expected as (
    select p.cp, p.year
    {% for column in crime_counts %}
        , coalesce(c.{{ column }}, 0) as {{ column }}
    {% endfor %}
    {% for column in license_counts %}
        , coalesce(l.{{ column }}, 0) as {{ column }}
    {% endfor %}
    {% for column in cumulative_counts %}
        , coalesce(h.{{ column }}, 0) as {{ column }}
    {% endfor %}
    from postal_years p
    left join expected_crimes c on c.cp = p.cp and c.year = p.year
    left join expected_licenses l on l.cp = p.cp and l.year = p.year
    left join expected_cumulative_licenses h on h.cp = p.cp and h.year = p.year
),

published as (
    select cp, year
    {% for column in count_columns %}
        , {{ column }}
    {% endfor %}
        , count(*) over (partition by cp, year) as rows_per_key
    from {{ ref('mart_crimes_pet_licenses') }}
)

select coalesce(e.cp, p.cp) as cp, coalesce(e.year, p.year) as year,
       case
           when p.rows_per_key is null then 'missing_postal_year'
           when e.cp is null then 'unexpected_postal_year'
           when p.rows_per_key > 1 then 'duplicate_postal_year'
           else 'counts_mismatch'
       end as issue,
       p.rows_per_key
{% for column in count_columns %}
    , e.{{ column }} as expected_{{ column }}
    , p.{{ column }} as published_{{ column }}
{% endfor %}
from expected e
full outer join published p on p.cp = e.cp and p.year = e.year
where p.rows_per_key is null
    or e.cp is null
    or p.rows_per_key > 1
{% for column in count_columns %}
    or e.{{ column }} is distinct from p.{{ column }}
{% endfor %}
