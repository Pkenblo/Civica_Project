-- Catálogo común de informes policiales, no una unión directa de delitos con arrestos.
-- Staging aplica la correspondencia de formatos; el número original permanece en RAW.
-- Grano: un número de informe común no nulo, aunque solo exista en uno de los orígenes.
-- La clave depende del número, no de la fuente, de los hechos asociados ni del orden de carga.
-- report_date_time procede de delitos, con hora y sin conversión de zona horaria.
-- Si falta esa fecha, queda NULL; no se sustituye por fechas del arresto.
-- Si un número tiene fechas diferentes, conserva las variantes para que falle unique,
-- sin escoger arbitrariamente la primera o la última.

with report_numbers as (

    select report_number
    from {{ ref('stg_crimes') }}

    union

    select report_number
    from {{ ref('stg_arrests') }}

),

report_dates as (

    select distinct report_number, report_date_time
    from {{ ref('stg_crimes') }}
    where report_number is not null
      and report_date_time is not null

)

select
      {{ dbt_utils.generate_surrogate_key(['report_numbers.report_number']) }} as report_id
    , report_numbers.report_number
    , report_dates.report_date_time
from report_numbers
left join report_dates
    on report_numbers.report_number = report_dates.report_number
where report_numbers.report_number is not null
