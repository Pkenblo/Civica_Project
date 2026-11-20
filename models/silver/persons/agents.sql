{{ config(materialized='table') }}

select md5(officer_id) as agent_key, officer_id, officer_gender, officer_race,
       officer_squad as squad_description, officer_title, ingested_at
from {{ ref('stg_arrests') }}
where officer_id is not null
qualify row_number() over (
    partition by officer_id
    order by ingested_at desc nulls last, arrest_occurred_date_time desc nulls last,
             source_file desc nulls last, batch_id desc nulls last,
             officer_gender desc nulls last, officer_race desc nulls last,
             officer_squad desc nulls last, officer_title desc nulls last
) = 1
