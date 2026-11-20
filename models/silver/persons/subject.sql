{{ config(materialized='table') }}

select md5(subject_id) as subject_key, subject_id as sk_person, subject_gender, subject_race, ingested_at
from {{ ref('stg_arrests') }}
where subject_id is not null
qualify row_number() over (
    partition by subject_id
    order by ingested_at desc nulls last, arrest_occurred_date_time desc nulls last,
             source_file desc nulls last, batch_id desc nulls last,
             subject_gender desc nulls last, subject_race desc nulls last
) = 1
