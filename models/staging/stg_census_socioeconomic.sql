-- stg_census_socioeconomic.sql
-- Normaliza ACS 2024 5-year por ZCTA y conserva solo códigos con prefijo 981, sin deduplicar.
-- El prefijo no equivale al límite municipal exacto de Seattle.
-- Los marcadores superiores se conservan con flags: no son importes medidos exactos.

with source as (

    select *
    from {{ source('brz_census_socioeconomic', 'census_socioeconomic') }}

),

renamed as (

    select
          nullif(upper(trim(NAME::varchar)), '') as zcta_name
        , {{ nullif_any("try_to_number(trim(B19013_001E::varchar))", -999999999, -888888888, -666666666, -555555555, -333333333, -222222222) }} as median_household_income
        , {{ nullif_any("try_to_number(trim(B19013_001M::varchar))", -999999999, -888888888, -666666666, -555555555, -333333333, -222222222) }} as income_margin_of_error
        , {{ nullif_any("try_to_number(trim(B01003_001E::varchar))", -999999999, -888888888, -666666666, -555555555, -333333333, -222222222) }} as population
        , {{ nullif_any("try_to_number(trim(B25077_001E::varchar))", -999999999, -888888888, -666666666, -555555555, -333333333, -222222222) }} as median_home_value
        , {{ nullif_any("try_to_number(trim(B25058_001E::varchar))", -999999999, -888888888, -666666666, -555555555, -333333333, -222222222) }} as median_monthly_rent
        -- Validar antes del cast evita truncar códigos o inventar ceros en códigos incompletos.
        , case
            when regexp_like(trim(ZCTA), '^[0-9]{5}$') then trim(ZCTA)
          end::varchar(5) as cp
        , INGESTED_AT as ingested_at
        , SOURCE_FILE as source_file
        , BATCH_ID as batch_id

    from source

)

select
      renamed.*
    , coalesce(median_household_income = 250001, false) as income_top_coded
    , coalesce(median_home_value = 2000001, false) as home_value_top_coded
    , coalesce(median_monthly_rent = 3501, false) as rent_top_coded
from renamed
where cp like '981%'
