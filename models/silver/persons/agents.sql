{{ config(materialized='table') }}

select {{ dbt_utils.generate_surrogate_key(['officer_id']) }} as agent_key, officer_id, officer_gender, officer_race
from {{ ref('stg_arrests') }}
where officer_id is not null
qualify row_number() over (
    partition by officer_id
    order by ingested_at desc nulls last, arrest_occurred_date_time desc nulls last,
             source_file desc nulls last, batch_id desc nulls last,
             officer_gender desc nulls last, officer_race desc nulls last
) = 1
