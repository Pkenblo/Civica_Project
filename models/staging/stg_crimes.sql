-- stg_crimes.sql
-- Normaliza nombres, tipos y marcadores de los datos de delitos.
-- Textos descriptivos y códigos en mayúsculas; identificadores y trazabilidad sin cambiar de caso.
-- Coordenadas persistidas a cinco decimales; los indicadores validan los valores RAW antes de redondear.

with source as (

    select *
    from {{ source('brz_crimes', 'crimes') }}

),

renamed as (

    select
          nullif(trim(REPORT_NUMBER), '') as report_number
        , to_timestamp_ntz(trim(REPORT_DATE_TIME), 'MM/DD/YYYY HH12:MI:SS AM') as report_date_time
        , nullif(trim(OFFENSE_ID), '') as offense_id
        , to_timestamp_ntz(trim(OFFENSE_DATE), 'MM/DD/YYYY HH12:MI:SS AM') as offense_date
        , {{ nullif_any("upper(trim(NIBRS_GROUP_A_B))", "", "-") }} as nibrs_group_a_b
        , {{ nullif_any("upper(trim(NIBRS_CRIME_AGAINST_CATEGORY))", "", "-") }} as nibrs_crime_against_category
        , {{ nullif_any("upper(trim(OFFENSE_SUB_CATEGORY))", "", "-") }} as offense_sub_category
        , {{ nullif_any("upper(trim(SHOOTING_TYPE_GROUP))", "", "-") }} as shooting_type_group

        , case
            when upper(trim(BLOCK_ADDRESS)) in ('', '-', 'REDACTED')
                then null
            else upper(trim(BLOCK_ADDRESS))
          end as block_address

        , round(nullif(try_to_decimal(trim(LATITUDE), 18, 12), -1), 5)::number(18, 5) as latitude
        , round(nullif(try_to_decimal(trim(LONGITUDE), 18, 12), -1), 5)::number(18, 5) as longitude
        , {{ nullif_any("upper(trim(BEAT))", "", "-") }} as beat
        , {{ nullif_any("upper(trim(PRECINCT))", "", "-") }} as precinct
        , {{ nullif_any("upper(trim(SECTOR))", "", "-") }} as sector
        , {{ nullif_any("upper(trim(NEIGHBORHOOD))", "", "-") }} as neighborhood
        , {{ nullif_any("upper(trim(REPORTING_AREA))", "", "-", "REDACTED") }} as reporting_area
        , {{ nullif_any("upper(trim(OFFENSE_CATEGORY))", "", "-") }} as offense_category
        , NIBRS_OFFENSE_CODE_DESCRIPTION as nibrs_offense_code_description_original
        , NIBRS_OFFENSE_CODE as nibrs_offense_code_original
        , {{ nullif_any("upper(trim(NIBRS_OFFENSE_CODE_DESCRIPTION))", "", "-") }} as nibrs_offense_code_description
        , {{ nullif_any("upper(trim(NIBRS_OFFENSE_CODE))", "", "-") }} as nibrs_offense_code
        , {{ nullif_any("upper(trim(CENSUS_BLOCK_2020))", "", "-", "REDACTED") }} as census_block_2020

        , coalesce(
            'REDACTED' in (
                upper(trim(BLOCK_ADDRESS)),
                upper(trim(LATITUDE)),
                upper(trim(LONGITUDE))
            ),
            false
          ) as is_location_redacted

        -- Ausencia y conversión fallida se distinguen antes de perder los marcadores RAW.
        , coalesce(
            LATITUDE is null or trim(LATITUDE) in ('', '-')
            or try_to_decimal(trim(LATITUDE), 18, 12) = -1
            or LONGITUDE is null or trim(LONGITUDE) in ('', '-')
            or try_to_decimal(trim(LONGITUDE), 18, 12) = -1,
            false
          ) as has_missing_coordinates

        , coalesce(
            (upper(trim(LATITUDE)) not in ('', '-', 'REDACTED')
                and try_to_decimal(trim(LATITUDE), 18, 12) is null)
            or (upper(trim(LONGITUDE)) not in ('', '-', 'REDACTED')
                and try_to_decimal(trim(LONGITUDE), 18, 12) is null)
            or try_to_decimal(trim(LATITUDE), 18, 12) not between -90 and 90
            or try_to_decimal(trim(LONGITUDE), 18, 12) not between -180 and 180,
            false
          ) as has_invalid_coordinates

        , _INGESTED_AT as ingested_at
        , _SOURCE_FILE as source_file
        , _BATCH_ID as batch_id

    from source

)

-- Una versión ocultada no aporta ubicación.
select * replace (
      iff(is_location_redacted, null, block_address) as block_address
    , iff(is_location_redacted, null, latitude) as latitude
    , iff(is_location_redacted, null, longitude) as longitude
    , iff(is_location_redacted, null, neighborhood) as neighborhood
    , iff(is_location_redacted, null, reporting_area) as reporting_area
    , iff(is_location_redacted, null, census_block_2020) as census_block_2020
)
from renamed
