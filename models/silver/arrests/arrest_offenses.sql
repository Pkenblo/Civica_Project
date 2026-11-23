{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='arrest_offense_id',
    on_schema_change='fail'
) }}

with observations as (
    select
          s.arrest_number
        , s.nibrs_description
        , max(s.ingested_at) as ingested_at
    from {{ ref('stg_arrests') }} s
    where s.nibrs_description is not null
      and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
    group by
          s.arrest_number
        , s.nibrs_description
),
-- Solo una descripción que identifica una única fila del catálogo puede aportar FK.
nibrs_descriptions as (
    select
          offense_description
        , count(*) as match_count
        , iff(count(*) = 1, min(nibrs_key), null) as nibrs_key
    from {{ ref('nibrs') }}
    where offense_description is not null
    group by offense_description
)

select
      {{ dbt_utils.generate_surrogate_key(['a.arrest_number', 'o.nibrs_description']) }} as arrest_offense_id
    , a.arrest_number
    , n.nibrs_key
    , case
        when n.match_count = 1 then 'matched'
        when n.match_count > 1 then 'ambiguous'
        else 'unmatched'
      end as nibrs_match_status
    , iff(coalesce(n.match_count, 0) <> 1, o.nibrs_description, null) as unresolved_nibrs_description
    , o.ingested_at
from observations o
join {{ ref('arrest') }} a on a.arrest_number = o.arrest_number
left join nibrs_descriptions n on n.offense_description = o.nibrs_description
