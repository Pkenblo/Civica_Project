-- Cobertura por clave de negocio: un recuento total igual no basta para detectar pérdidas.
-- Las llegadas omitidas por el corte incremental también se señalan; no se reparan aquí.
with keys_by_layer as (
    select distinct 'crime' as source,
           {{ dbt_utils.generate_surrogate_key([dbt_utils.generate_surrogate_key(['report_number']), 'offense_id']) }} as event_id,
           'staging' as layer
    from {{ ref('stg_crimes') }}
    where report_number is not null and offense_id is not null and ingested_at is not null
    union all
    select distinct 'arrest', arrest_number, 'staging'
    from {{ ref('stg_arrests') }}
    where arrest_number is not null and ingested_at is not null
    union all
    select 'crime', crime_id, 'silver' from {{ ref('crimes') }}
    union all
    select 'arrest', arrest_number, 'silver' from {{ ref('arrest') }}
    union all
    select 'crime', crime_id, 'gold' from {{ ref('fact_crimes') }}
    union all
    select 'arrest', arrest_number, 'gold' from {{ ref('fact_arrests') }}
)
select source, event_id
from keys_by_layer
group by source, event_id
having event_id is null
    or count(case when layer = 'staging' then 1 end) <> 1
    or count(case when layer = 'silver' then 1 end) <> 1
    or count(case when layer = 'gold' then 1 end) <> 1
