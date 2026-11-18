-- stg_zipcode_areas.sql
-- Extrae y normaliza las propiedades y geometrías de las zonas postales.

with source as (

    select *
    from {{ source('brz_zipcode_areas', 'zipcode_areas') }}

),

renamed as (

    select
          try_to_number(FEATURE:properties:OBJECTID::varchar)                as object_id
        , nullif(trim(FEATURE:properties:ZIPCODE::varchar), '')              as zip_code
        , nullif(trim(FEATURE:properties:ZIP_TYPE::varchar), '')             as zip_type
        , nullif(trim(FEATURE:properties:COUNTY_NAME::varchar), '')          as county_name
        , nullif(trim(FEATURE:properties:PREFERRED_CITY::varchar), '')      as preferred_city
        , try_to_geography(FEATURE:geometry)                                as geography
        , nullif(trim(BOUNDARY_VERSION), '')                                as boundary_version
        , _INGESTED_AT                                                      as ingested_at
        , _SOURCE_FILE                                                      as source_file
        , _BATCH_ID                                                         as batch_id

    from source

)

select *
from renamed
