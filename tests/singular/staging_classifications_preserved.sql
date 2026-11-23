-- Los originales se comparan con RAW incluyendo marcadores, nulos y multiplicidades.
with expected as (
    select 'arrests' as domain,
           {{ dbt_utils.generate_surrogate_key(['OFFENSE_TYPE', 'NIBRS_DESCRIPTION']) }} as classification_id,
           count(*) as source_rows
    from {{ source('brz_arrests', 'arrests') }}
    group by 1, 2

    union all

    select 'crimes', {{ dbt_utils.generate_surrogate_key(['NIBRS_OFFENSE_CODE', 'NIBRS_OFFENSE_CODE_DESCRIPTION']) }}, count(*)
    from {{ source('brz_crimes', 'crimes') }}
    group by 1, 2
),
actual as (
    select 'arrests' as domain,
           {{ dbt_utils.generate_surrogate_key(['offense_type_original', 'nibrs_description_original']) }} as classification_id,
           count(*) as source_rows
    from {{ ref('stg_arrests') }}
    group by 1, 2

    union all

    select 'crimes', {{ dbt_utils.generate_surrogate_key(['nibrs_offense_code_original', 'nibrs_offense_code_description_original']) }}, count(*)
    from {{ ref('stg_crimes') }}
    group by 1, 2
)
select coalesce(e.domain, a.domain) as domain,
       coalesce(e.classification_id, a.classification_id) as classification_id,
       e.source_rows as expected_rows, a.source_rows as actual_rows
from expected e
full outer join actual a on a.domain = e.domain and a.classification_id = e.classification_id
where e.classification_id is null or a.classification_id is null or e.source_rows <> a.source_rows
