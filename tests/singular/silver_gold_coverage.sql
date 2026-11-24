{{ config(
    fail_calc='coalesce(max(failure_level), 0)',
    error_if='= 2',
    warn_if='= 1'
) }}

{% set staging_report_id = dbt_utils.generate_surrogate_key(['report_number']) %}

with observed as (
    select 'crimes' as dataset,
           {{ dbt_utils.generate_surrogate_key([staging_report_id, 'offense_id']) }} as record_key,
           ingested_at
    from {{ ref('stg_crimes') }}
    where report_number is not null and offense_id is not null and ingested_at is not null

    union all
    select 'arrests', arrest_number, ingested_at
    from {{ ref('stg_arrests') }}
    where arrest_number is not null and ingested_at is not null

    union all
    select 'licenses', license_number, ingested_at
    from {{ ref('stg_pet_licenses') }}
    where license_number is not null and ingested_at is not null
),

published as (
    select 'silver' as layer, 'crimes' as dataset, crime_id as record_key, ingested_at
    from {{ ref('crimes') }}
    union all
    select 'silver', 'arrests', arrest_number, ingested_at from {{ ref('arrest') }}
    union all
    select 'silver', 'licenses', license_number, ingested_at from {{ ref('licenses') }}
    union all
    select 'gold', 'crimes', crime_id, ingested_at from {{ ref('fact_crimes') }}
    union all
    select 'gold', 'arrests', arrest_number, ingested_at from {{ ref('fact_arrests') }}
    union all
    select 'gold', 'licenses', license_number, ingested_at from {{ ref('dim_licenses') }}
),

expected as (
    select 'silver' as layer, dataset, record_key, max(ingested_at) as ingested_at
    from observed
    group by dataset, record_key

    union all
    select 'gold', dataset, record_key, ingested_at
    from published
    where layer = 'silver'
),

cutoffs as (
    select layer, dataset, max(ingested_at) as watermark
    from published
    group by layer, dataset
)

select e.layer, e.dataset, e.record_key, e.ingested_at as expected_ingested_at,
       p.ingested_at as published_ingested_at, c.watermark,
       case
           -- El corte previo no se conoce: una brecha antigua puede ser una llegada tardía.
           -- La dimensión de licencias es una vista y no aplica un segundo corte.
           when (e.layer = 'silver' or e.dataset <> 'licenses')
                and e.ingested_at <= c.watermark
                and (p.ingested_at is null or p.ingested_at < e.ingested_at) then 1
           else 2
       end as failure_level
from expected e
left join published p using (layer, dataset, record_key)
left join cutoffs c using (layer, dataset)
where p.record_key is null or p.ingested_at is distinct from e.ingested_at
