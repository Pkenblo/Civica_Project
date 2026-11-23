{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='report_id',
    on_schema_change='fail'
) }}

with observations as (
    select s.report_number, s.ingested_at
    from {{ ref('stg_crimes') }} s
    where s.report_number is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
    union all
    select s.report_number, s.ingested_at
    from {{ ref('stg_arrests') }} s
    where s.report_number is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
),
numbers as (
    select report_number, max(ingested_at) as ingested_at
    from observations
    group by report_number
),
crime_reports as (
    -- Recuperar la fecha de delitos también si el lote solo aporta detenciones.
    select s.report_number, s.report_date_time
    from {{ ref('stg_crimes') }} s
    join numbers n on n.report_number = s.report_number
    where s.ingested_at is not null
    qualify row_number() over (
        partition by s.report_number
        order by s.ingested_at desc nulls last, s.source_file desc nulls last,
                 s.batch_id desc nulls last, s.report_date_time desc nulls last
    ) = 1
)
select {{ dbt_utils.generate_surrogate_key(['n.report_number']) }} as report_id,
       n.report_number, c.report_date_time, n.ingested_at
from numbers n
left join crime_reports c using (report_number)
