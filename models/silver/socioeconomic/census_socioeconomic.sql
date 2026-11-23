{{ config(
    materialized='table',
    tags=['static_model']
) }}

with latest as (
    select s.*
    from {{ ref('stg_census_socioeconomic') }} s
    where s.cp is not null
    qualify row_number() over (
        partition by s.cp
        order by
              s.ingested_at desc nulls last
            , s.source_file desc nulls last
            , s.batch_id desc nulls last
            , s.zcta_name desc nulls last
            , s.median_household_income desc nulls last
            , s.income_margin_of_error desc nulls last
            , s.population desc nulls last
            , s.median_home_value desc nulls last
            , s.median_monthly_rent desc nulls last
    ) = 1
)
-- Relación lógica por código: cp = postal_codes.cp. ZCTA y ZIP no tienen límites idénticos.
-- Sin join: conservar también los ZCTA nacionales ausentes del catálogo postal local.
select
      cp
    , zcta_name
    , median_household_income
    , income_margin_of_error
    , population
    , median_home_value
    , median_monthly_rent
    , income_top_coded
    , home_value_top_coded
    , rent_top_coded
    , ingested_at
    , source_file
    , batch_id
from latest
