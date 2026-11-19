-- Detalle de infracciones: una combinación de arresto, tipo y descripción NIBRS observada.
-- Se extrae antes de deduplicar Arrest y se conserva nibrs_description en el detalle.
-- No impone unicidad solo a (arrest_number, offense_type_id): puede cambiar la descripción.
-- Elimina duplicados completos y no crea una infracción cuando ambos textos están ausentes.
-- Conserva asociaciones observadas; no reconstruye bajas ni vigencias del origen.

{{ config(materialized='table', database=env_var('DBT_SILVER'), schema='SILVER') }}

with offenses as (

    select distinct arrest_number, offense_type, nibrs_description
    from {{ ref('stg_arrests') }}
    where arrest_number is not null
      and (offense_type is not null or nibrs_description is not null)

)

select
      {{ dbt_utils.generate_surrogate_key([
          'offenses.arrest_number',
          'offenses.offense_type',
          'offenses.nibrs_description'
      ]) }} as arrest_offense_id
    , offenses.arrest_number
    , types.offense_type_id
    , offenses.nibrs_description
from offenses
left join {{ ref('offense_types') }} as types
    on offenses.offense_type = types.offense_type
