-- Perfil de la tabla de sustitución completa; no se presupone el nombre de su lote.
with profile as (
    select count(*) as rows_loaded,
           count(distinct trim(ZCTA)) as zcta_codes,
           coalesce(count_if(try_to_number(B19013_001E::varchar) = -666666666), 0) as income_missing,
           coalesce(count_if(try_to_number(B19013_001M::varchar) = -333333333), 0) as moe_limited,
           coalesce(count_if(try_to_number(B19013_001M::varchar) = -222222222), 0) as moe_not_applicable,
           coalesce(count_if(try_to_number(B25077_001E::varchar) = -666666666), 0) as home_missing,
           coalesce(count_if(try_to_number(B25058_001E::varchar) = -666666666), 0) as rent_missing,
           coalesce(count_if(try_to_number(B19013_001E::varchar) = 250001), 0) as income_top,
           coalesce(count_if(try_to_number(B25077_001E::varchar) = 2000001), 0) as home_top,
           coalesce(count_if(try_to_number(B25058_001E::varchar) = 3501), 0) as rent_top
    from {{ source('brz_census_socioeconomic', 'census_socioeconomic') }}
)
select * from profile
where rows_loaded <> 33772 or zcta_codes <> 33772
   or income_missing <> 3225 or moe_limited <> 133 or moe_not_applicable <> 3225
   or home_missing <> 3512 or rent_missing <> 8218
   or income_top <> 118 or home_top <> 100 or rent_top <> 89
