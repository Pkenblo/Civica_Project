-- Comprueba ambos sentidos: ninguna clave desaparece y Silver conserva la última fila completa.
with expected as (
    select *
    from {{ ref('stg_census_socioeconomic') }}
    qualify row_number() over (
        partition by cp
        order by ingested_at desc nulls last, source_file desc nulls last, batch_id desc nulls last,
                 zcta_name desc nulls last, median_household_income desc nulls last,
                 income_margin_of_error desc nulls last, population desc nulls last,
                 median_home_value desc nulls last, median_monthly_rent desc nulls last
    ) = 1
),
missing_or_changed as (
    select cp, zcta_name,
           median_household_income, income_margin_of_error, population, median_home_value, median_monthly_rent,
           income_top_coded, home_value_top_coded, rent_top_coded, ingested_at, source_file, batch_id
    from expected
    minus
    select * from {{ ref('census_socioeconomic') }}
),
unexpected as (
    select * from {{ ref('census_socioeconomic') }}
    minus
    select cp, zcta_name,
           median_household_income, income_margin_of_error, population, median_home_value, median_monthly_rent,
           income_top_coded, home_value_top_coded, rent_top_coded, ingested_at, source_file, batch_id
    from expected
)
select * from missing_or_changed
union all
select * from unexpected
