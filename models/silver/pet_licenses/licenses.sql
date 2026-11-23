{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='license_number',
    on_schema_change='fail'
) }}

with latest as (
    select s.*
    from {{ ref('stg_pet_licenses') }} s
    where s.license_number is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
    qualify row_number() over (
        partition by s.license_number
        order by s.ingested_at desc, s.license_issue_date desc nulls last,
                 s.source_file desc nulls last, s.batch_id desc nulls last,
                 s.animal_name desc nulls last, s.species desc nulls last,
                 s.primary_breed desc nulls last, s.secondary_breed desc nulls last, s.zip_code desc nulls last
    ) = 1
)
select {{ dbt_utils.generate_surrogate_key(['license_number', 'animal_name']) }} as license_id,
       license_number, license_issue_date, animal_name, species, primary_breed, secondary_breed,
       iff(regexp_like(zip_code, '^[0-9]{5}$'), zip_code, null) as cp, ingested_at
from latest
