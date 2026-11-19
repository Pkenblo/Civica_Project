-- stg_arrests.sql
-- Normaliza nombres, tipos y marcadores de los registros de detenciones.
-- Textos descriptivos y códigos en mayúsculas; identificadores y trazabilidad sin cambiar de caso.
-- El informe YYYY0000NNNNNN se publica como YYYY-NNNNNN; el valor original sigue en RAW.
-- Coordenadas persistidas a cinco decimales; los indicadores validan los valores RAW antes de redondear.

with source as (

    select *
    from {{ source('brz_arrests', 'arrests') }}

),

renamed as (

    select
          nullif(trim(ARREST_NUMBER), '')                                                               as arrest_number
        , to_timestamp_ntz(trim(ARREST_OCCURRED_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM')                 as arrest_occurred_date_time
        , to_timestamp_ntz(trim(ARREST_REPORTED_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM')                 as arrest_reported_date_time
        , {{ nullif_any("upper(trim(regexp_replace(ARREST_TYPE, '[[:space:]]+', ' ')))", "", "-") }}     as arrest_type
        , {{ nullif_any("upper(trim(BEAT))", "", "-") }}                                                as beat
        , {{ nullif_any("upper(trim(CAD_CLEARANCE))", "", "-") }}                                       as cad_clearance
        , {{ nullif_any("upper(trim(CAD_INITIAL_CALL_TYPE))", "", "-") }}                               as cad_initial_call_type
        , nullif(try_to_number(trim(CAD_PRIORITY)), -1)                                                 as cad_priority
        , try_to_boolean(trim(CRISIS_INVOLVED))                                                         as crisis_involved
        , try_to_boolean(trim(COMPLAINT_INVOLVED))                                                      as complaint_involved
        , try_to_boolean(trim(FORCE_INVOLVED))                                                          as force_involved
        , {{ nullif_any("upper(trim(NIBRS_DESCRIPTION))", "", "-") }}                                   as nibrs_description
        , {{ nullif_any("upper(trim(OFFENSE_TYPE))", "", "-") }}                                        as offense_type
        , nullif(try_to_number(trim(OFFICER_AGE)), -1)                                                  as officer_age
        , {{ nullif_any("upper(trim(OFFICER_GENDER))", "", "-") }}                                      as officer_gender
        , nullif(trim(OFFICER_ID), '')                                                                  as officer_id
        , {{ nullif_any("upper(trim(OFFICER_RACE))", "", "-") }}                                        as officer_race
        , {{ nullif_any("upper(trim(AS_ON_SQUAD_DESC))", "", "-") }}                                    as officer_squad
        , {{ nullif_any("upper(trim(INV_OFFICER_TITLE))", "", "-") }}                                   as officer_title
        , {{ nullif_any("upper(trim(PRECINCT))", "", "-") }}                                            as precinct
        , case
            when regexp_like(trim(REPORT_NUMBER), '^[0-9]{4}0000[0-9]{6}$')
                then left(trim(REPORT_NUMBER), 4) || '-' || right(trim(REPORT_NUMBER), 6)
            else nullif(trim(REPORT_NUMBER), '')
          end                                                                                           as report_number
        , {{ nullif_any("upper(trim(SECTOR))", "", "-") }}                                              as sector
        , {{ nullif_any("upper(trim(SUBJECT_AGE_RANGE))", "", "-") }}                                   as subject_age_range
        , {{ nullif_any("upper(trim(SUBJECT_GENDER))", "", "-") }}                                      as subject_gender
        , {{ nullif_any("trim(SK_PERSON)", "", "-1") }}                                                 as subject_id
        , {{ nullif_any("upper(trim(SUBJECT_RACE))", "", "-") }}                                        as subject_race
        , try_to_boolean(trim(TERRY_STOP))                                                              as terry_stop

        , case
            when upper(trim(BLOCK_ADDRESS)) in ('', '-', 'REDACTED')
                then null
            else upper(trim(BLOCK_ADDRESS))
          end                                                                                           as block_address

        , round(nullif(try_to_decimal(trim(LATITUDE), 18, 12), -1), 5)::number(18, 5)                   as latitude
        , round(nullif(try_to_decimal(trim(LONGITUDE), 18, 12), -1), 5)::number(18, 5)                  as longitude
        , {{ nullif_any("upper(trim(NEIGHBORHOOD))", "", "-") }}                                        as neighborhood
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

        -- Solo valida conversión y rangos globales; estar fuera de Seattle no es un error.
        , coalesce(
            LATITUDE is null or trim(LATITUDE) in ('', '-')
            or try_to_decimal(trim(LATITUDE), 18, 12) = -1
            or LONGITUDE is null or trim(LONGITUDE) in ('', '-')
            or try_to_decimal(trim(LONGITUDE), 18, 12) = -1,
            false
          )                                                                                             as has_missing_coordinates

        , coalesce(
            (upper(trim(LATITUDE)) not in ('', '-', 'REDACTED')
                and try_to_decimal(trim(LATITUDE), 18, 12) is null)
            or (upper(trim(LONGITUDE)) not in ('', '-', 'REDACTED')
                and try_to_decimal(trim(LONGITUDE), 18, 12) is null)
            or try_to_decimal(trim(LATITUDE), 18, 12) not between -90 and 90
            or try_to_decimal(trim(LONGITUDE), 18, 12) not between -180 and 180,
            false
          )                                                                                             as has_invalid_coordinates

        , _INGESTED_AT                                                                                  as ingested_at
        , _SOURCE_FILE                                                                                  as source_file
        , _BATCH_ID                                                                                     as batch_id

    from source

)

select *
from renamed
