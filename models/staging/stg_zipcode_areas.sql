-- stg_zipcode_areas.sql
-- Extrae y normaliza las propiedades y geometrías de las zonas postales.
-- Textos descriptivos en mayúsculas; versión cartográfica y trazabilidad sin cambiar de caso.
-- Recorte por prefijo 981; no equivale al límite municipal exacto de Seattle.

with source as (

    select *
    from {{ source('brz_zipcode_areas', 'zipcode_areas') }}

),

renamed as (

    select
          try_to_number(FEATURE:properties:OBJECTID::varchar) as object_id
        , nullif(upper(trim(FEATURE:properties:ZIPCODE::varchar)), '') as zip_code
        , nullif(upper(trim(FEATURE:properties:ZIP_TYPE::varchar)), '') as zip_type
        , nullif(upper(trim(FEATURE:properties:COUNTY_NAME::varchar)), '') as county_name
        , nullif(upper(trim(FEATURE:properties:PREFERRED_CITY::varchar)), '') as preferred_city
        , try_to_geography(FEATURE:geometry) as geography
        , nullif(trim(BOUNDARY_VERSION), '') as boundary_version
        , _INGESTED_AT as ingested_at
        , _SOURCE_FILE as source_file
        , _BATCH_ID as batch_id

    from source

)

select *
from renamed
where zip_code like '981%'
