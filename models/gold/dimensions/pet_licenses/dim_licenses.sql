with current_rows as (
    select
          l.license_number
        , l.license_id
        , l.license_issue_date
        , d.date_key as license_issue_date_key
        , l.animal_name
        , l.species
        , l.primary_breed
        , l.secondary_breed
        , l.cp
        , l.ingested_at
        , case
            when l.species = 'DOG' then 'dog'
            when l.species = 'CAT' then 'cat'
            when l.species is null then 'unknown'
            else 'other'
          end as species_group
    from {{ ref('licenses') }} l
    left join {{ ref('dim_date') }} d on d.full_date = l.license_issue_date
)

select *
from current_rows
