-- stg_pet_licenses.sql
-- Normaliza nombres y convierte la fecha de las licencias de mascotas.
-- Nombres y categorías en mayúsculas; identificadores y trazabilidad sin cambiar de caso.
-- Recorte por prefijo 981; no equivale al límite municipal exacto de Seattle.

with source as (

    select *
    from {{ source('brz_pet_licenses', 'pet_licenses') }}

),

renamed as (

    select
          to_date(trim(LICENSE_ISSUE_DATE), 'MMMM DD YYYY') as license_issue_date
        , nullif(trim(LICENSE_NUMBER), '') as license_number
        , nullif(upper(trim(ANIMAL_S_NAME)), '') as animal_name
        , {{ nullif_any("upper(trim(SPECIES))", "", "UNKNOWN", "-") }} as species
        , nullif(upper(trim(PRIMARY_BREED)), '') as primary_breed
        , nullif(upper(trim(SECONDARY_BREED)), '') as secondary_breed
        , nullif(upper(trim(ZIP_CODE)), '') as zip_code
        , _INGESTED_AT as ingested_at
        , _SOURCE_FILE as source_file
        , _BATCH_ID as batch_id

    from source

)

select *
from renamed
where zip_code like '981%'
