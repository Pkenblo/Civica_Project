-- stg_arrests.sql
-- Normaliza nombres, tipos y marcadores de los registros de detenciones.

with source as (

    select *
    from {{ source('brz_arrests', 'arrests') }}

),

renamed as (

    select
          nullif(trim(ARREST_NUMBER), '')                                                               as arrest_number
        , to_timestamp_ntz(trim(ARREST_OCCURRED_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM')                 as arrest_occurred_date_time
        , to_timestamp_ntz(trim(ARREST_REPORTED_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM')                 as arrest_reported_date_time
        , {{ nullif_any("trim(ARREST_TYPE)", "", "-") }}                                                as arrest_type
        , {{ nullif_any("trim(BEAT)", "", "-") }}                                                       as beat
        , {{ nullif_any("trim(CAD_CLEARANCE)", "", "-") }}                                              as cad_clearance
        , {{ nullif_any("trim(CAD_INITIAL_CALL_TYPE)", "", "-") }}                                      as cad_initial_call_type
        , nullif(try_to_number(trim(CAD_PRIORITY)), -1)                                                 as cad_priority
        , try_to_boolean(trim(CRISIS_INVOLVED))                                                         as crisis_involved
        , try_to_boolean(trim(COMPLAINT_INVOLVED))                                                      as complaint_involved
        , try_to_boolean(trim(FORCE_INVOLVED))                                                          as force_involved
        , {{ nullif_any("trim(NIBRS_DESCRIPTION)", "", "-") }}                                          as nibrs_description
        , {{ nullif_any("trim(OFFENSE_TYPE)", "", "-") }}                                               as offense_type
        , nullif(try_to_number(trim(OFFICER_AGE)), -1)                                                  as officer_age
        , nullif(trim(OFFICER_GENDER), '')                                                              as officer_gender
        , nullif(trim(OFFICER_ID), '')                                                                  as officer_id
        , nullif(trim(OFFICER_RACE), '')                                                                as officer_race
        , {{ nullif_any("trim(AS_ON_SQUAD_DESC)", "", "-") }}                                           as officer_squad
        , {{ nullif_any("trim(INV_OFFICER_TITLE)", "", "-") }}                                          as officer_title
        , {{ nullif_any("trim(PRECINCT)", "", "-") }}                                                   as precinct
        , nullif(trim(REPORT_NUMBER), '')                                                               as report_number
        , {{ nullif_any("trim(SECTOR)", "", "-") }}                                                     as sector
        , nullif(trim(SUBJECT_AGE_RANGE), '')                                                           as subject_age_range
        , nullif(trim(SUBJECT_GENDER), '')                                                              as subject_gender
        , {{ nullif_any("trim(SK_PERSON)", "", "-1") }}                                                 as subject_id
        , nullif(trim(SUBJECT_RACE), '')                                                                as subject_race
        , try_to_boolean(trim(TERRY_STOP))                                                              as terry_stop

        , case
            when upper(trim(BLOCK_ADDRESS)) in ('', '-', 'REDACTED')
                then null
            else trim(BLOCK_ADDRESS)
          end                                                                                           as block_address

        , nullif(try_to_decimal(trim(LATITUDE), 18, 12), -1)                                            as latitude
        , nullif(try_to_decimal(trim(LONGITUDE), 18, 12), -1)                                           as longitude
        , {{ nullif_any("trim(NEIGHBORHOOD)", "", "-") }}                                               as neighborhood
        , {{ nullif_any("upper(trim(REPORTING_AREA))", "", "-", "REDACTED") }}                          as reporting_area
        , try_to_boolean(trim(DEMONSTRATION))                                                           as demonstration
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