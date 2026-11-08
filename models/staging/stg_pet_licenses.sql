-- stg_pet_licenses.sql
-- Normaliza nombres y convierte la fecha de las licencias de mascotas.

with source as (

    select *
    from {{ source('brz_pet_licenses', 'pet_licenses') }}

),

renamed as (

    select
        to_date(trim(LICENSE_ISSUE_DATE), 'MMMM DD YYYY')         as license_issue_date
        , nullif(trim(LICENSE_NUMBER), '')                        as license_number
        , nullif(trim(ANIMAL_S_NAME), '')                         as animal_name
        , nullif(trim(SPECIES), '')                               as species
        , nullif(trim(PRIMARY_BREED), '')                         as primary_breed
        , nullif(trim(SECONDARY_BREED), '')                       as secondary_breed
        , nullif(trim(ZIP_CODE), '')                              as zip_code
        , _INGESTED_AT                                            as ingested_at
        , _SOURCE_FILE                                            as source_file
        , _BATCH_ID                                               as batch_id

    from source

)

select *
from renamed