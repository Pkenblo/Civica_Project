{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='crime_id',
    on_schema_change='fail'
) }}

with candidates as (
    select
          s.*
        , r.report_id
        , {{ dbt_utils.generate_surrogate_key(['r.report_id', 's.offense_id']) }} as crime_id
    from {{ ref('stg_crimes') }} s
    left join {{ ref('reports') }} r on s.report_number = r.report_number
    where s.report_number is not null and s.offense_id is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
),
resolved as (
    select
          s.crime_id
        , s.report_id
        , s.offense_id
        , s.offense_date
        , s.ingested_at
        , n.nibrs_key
        , c.offense_category_id
        , d.address_id
        , z.police_area_id
        , s.source_file
        , s.batch_id
    from candidates s
    left join {{ ref('nibrs') }} n on n.offense_code = s.nibrs_offense_code
    left join {{ ref('offense_categories') }} c on equal_null(c.offense_category, s.offense_category)
        and equal_null(c.offense_sub_category, s.offense_sub_category)
    left join {{ ref('police_add') }} z on equal_null(z.precinct, s.precinct)
        and equal_null(z.sector, s.sector) and equal_null(z.beat, s.beat)
    left join {{ ref('full_address') }} d on d.address_id = {{ address_id('s') }}
)

select * exclude (
      source_file
    , batch_id
)
from resolved
qualify row_number() over (
    partition by
          report_id
        , offense_id
    order by
          ingested_at desc
        , source_file desc nulls last
        , batch_id desc nulls last
        , offense_date desc nulls last
        , nibrs_key desc nulls last
        , offense_category_id desc nulls last
        , address_id desc nulls last
        , police_area_id desc nulls last
) = 1
