-- Puente entre arrest y nibrs: conserva cada combinación observada de arresto, tipo y descripción.
-- La descripción identifica un código solo si hay una coincidencia exacta y no ambigua.

{{ config(materialized='table', database=env_var('DBT_SILVER'), schema='SILVER') }}

with offenses as (

    select distinct arrest_number, offense_type, nibrs_description
    from {{ ref('stg_arrests') }}
    where arrest_number is not null
      and (offense_type is not null or nibrs_description is not null)

),

nibrs_by_description as (

    select offense_description, min(nibrs_key) as nibrs_key
    from {{ ref('nibrs') }}
    where offense_description is not null and nibrs_key is not null
    group by offense_description
    having count(distinct nibrs_key) = 1

)

select
      {{ dbt_utils.generate_surrogate_key([
          'offenses.arrest_number',
          'offenses.offense_type',
          'offenses.nibrs_description'
      ]) }} as arrest_offense_id
    , offenses.arrest_number
    , offenses.offense_type
    , offenses.nibrs_description
    , classifications.nibrs_key
from offenses
left join nibrs_by_description as classifications
    on offenses.nibrs_description = classifications.offense_description
