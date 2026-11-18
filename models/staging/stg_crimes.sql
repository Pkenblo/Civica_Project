-- stg_crimes.sql
-- Normaliza nombres, tipos y marcadores de los datos de delitos.

with source as (

    select *
    from {{ source('brz_crimes', 'crimes') }}

),

renamed as (

    select
          nullif(trim(REPORT_NUMBER), '')                                                               as report_number
        , to_timestamp_ntz(trim(REPORT_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM')                          as report_date_time
        , nullif(trim(OFFENSE_ID), '')                                                                  as offense_id
        , to_timestamp_ntz(trim(OFFENSE_DATE), 'MM/DD/YYYY HH12:MI:SS AM')                              as offense_date
        , {{ nullif_any("trim(NIBRS_GROUP_A_B)", "", "-") }}                                            as nibrs_group_a_b
        , {{ nullif_any("trim(NIBRS_CRIME_AGAINST_CATEGORY)", "", "-") }}                               as nibrs_crime_against_category
        , {{ nullif_any("trim(OFFENSE_SUB_CATEGORY)", "", "-") }}                                       as offense_sub_category
        , {{ nullif_any("trim(SHOOTING_TYPE_GROUP)", "", "-") }}                                        as shooting_type_group

        , case
            when upper(trim(BLOCK_ADDRESS)) in ('', '-', 'REDACTED')
                then null
            else trim(BLOCK_ADDRESS)
          end                                                                                           as block_address

        , nullif(try_to_decimal(trim(LATITUDE), 18, 12), -1)                                            as latitude
        , nullif(try_to_decimal(trim(LONGITUDE), 18, 12), -1)                                           as longitude
        , {{ nullif_any("trim(BEAT)", "", "-") }}                                                       as beat
        , {{ nullif_any("trim(PRECINCT)", "", "-") }}                                                   as precinct
        , {{ nullif_any("trim(SECTOR)", "", "-") }}                                                     as sector
        , {{ nullif_any("trim(NEIGHBORHOOD)", "", "-") }}                                               as neighborhood
        , {{ nullif_any("upper(trim(REPORTING_AREA))", "", "-", "REDACTED") }}                          as reporting_area
        , {{ nullif_any("trim(OFFENSE_CATEGORY)", "", "-") }}                                           as offense_category
        , {{ nullif_any("trim(NIBRS_OFFENSE_CODE_DESCRIPTION)", "", "-") }}                             as nibrs_offense_code_description
        , {{ nullif_any("trim(NIBRS_OFFENSE_CODE)", "", "-") }}                                         as nibrs_offense_code
        , {{ nullif_any("upper(trim(CENSUS_BLOCK_2020))", "", "-", "REDACTED") }}                       as census_block_2020

        , coalesce(
            'REDACTED' in (
                upper(trim(BLOCK_ADDRESS)),
                upper(trim(LATITUDE)),
                upper(trim(LONGITUDE))
            ),
            false
          )                                                                                             as is_location_redacted

        , _INGESTED_AT                                                                                  as ingested_at
        , _SOURCE_FILE                                                                                  as source_file
        , _BATCH_ID                                                                                     as batch_id

    from source

)

select *
from renamed