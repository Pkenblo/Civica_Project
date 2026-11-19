-- Delitos con referencias a informes, NIBRS, ubicación publicada y área policial.
-- La fecha del informe se consulta en Reports; no se duplica aquí ni se recupera report_number_source.
-- BORRADOR: conserva variantes base distintas de un offense_id y elimina solo duplicados completos.
-- No selecciona una última versión por ingested_at. El grano definitivo queda pendiente.
-- Los tipos de tiroteo se conservan aparte en crime_shooting_types.
-- La clave de ubicación se calcula con el contrato de Full_address, sin ocultar referencias faltantes.
-- depends_on: {{ ref('full_address') }}

{{ config(materialized='table', database=env_var('DBT_SILVER'), schema='SILVER') }}

with observations as (

    select distinct
          offense_id
        , report_number
        , offense_date
        , nibrs_offense_code
        , offense_category
        , offense_sub_category
        , precinct, sector, beat
        , block_address, latitude, longitude, neighborhood, reporting_area, census_block_2020
        , is_location_redacted, has_missing_coordinates, has_invalid_coordinates
        , case
            when is_location_redacted or has_missing_coordinates or has_invalid_coordinates
                then 'crimes:' || offense_id
            else null
          end as location_context
    from {{ ref('stg_crimes') }}
    where offense_id is not null

),

keyed as (

    -- Contrato compartido con full_address.sql; no incluir CP, estado ni versión del mapa.
    select
          observations.*
        , {{ dbt_utils.generate_surrogate_key([
              'block_address', 'latitude', 'longitude', 'neighborhood',
              'reporting_area', 'census_block_2020', 'is_location_redacted',
              'has_missing_coordinates', 'has_invalid_coordinates', 'location_context'
          ]) }} as address_id
    from observations

)

select distinct
      crimes.offense_id
    , reports.report_id
    , crimes.offense_date
    , nibrs.nibrs_key
    , crimes.offense_category
    , crimes.offense_sub_category
    , crimes.address_id
    , police.police_area_id
from keyed as crimes
left join {{ ref('reports') }} as reports
    on crimes.report_number = reports.report_number
left join {{ ref('nibrs') }} as nibrs
    on crimes.nibrs_offense_code = nibrs.offense_code
left join {{ ref('police_add') }} as police
    on equal_null(crimes.precinct, police.precinct)
    and equal_null(crimes.sector, police.sector)
    and equal_null(crimes.beat, police.beat)
