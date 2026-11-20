{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='crime_id',
    on_schema_change='fail'
) }}

with identified as (
    select s.*, r.report_id, md5(r.report_id || '|' || s.offense_id) as crime_id,
           iff(is_location_redacted or has_missing_coordinates or has_invalid_coordinates,
               'C:' || r.report_id || ':' || s.offense_id, null) as location_context
    from {{ ref('stg_crimes') }} s
    left join {{ ref('reports') }} r on s.report_number = r.report_number
    where s.report_number is not null and s.offense_id is not null and s.ingested_at is not null
),
candidates as (
    select i.* from identified i
    {% if is_incremental() %}
    left join {{ this }} t on i.crime_id = t.crime_id
    where t.ingested_at is null or i.ingested_at >= t.ingested_at
    {% endif %}
),
resolved as (
    select s.crime_id, s.report_id, s.offense_id, s.offense_date, s.ingested_at,
           n.nibrs_key, c.offense_category_id, sub.offense_subcategory_id, d.address_id, z.police_area_id,
           s.source_file, s.batch_id
    from candidates s
    left join {{ ref('nibrs') }} n on n.offense_code = s.nibrs_offense_code
    left join {{ ref('offense_categories') }} c on c.offense_category = s.offense_category
    left join {{ ref('offense_subcategories') }} sub on sub.offense_sub_category = s.offense_sub_category
        and equal_null(sub.offense_category_id, c.offense_category_id)
    left join {{ ref('police_add') }} z on equal_null(z.precinct, s.precinct)
        and equal_null(z.sector, s.sector) and equal_null(z.beat, s.beat)
    left join {{ ref('full_address') }} d on equal_null(d.location_context, s.location_context)
        {% for col in ['block_address', 'latitude', 'longitude', 'neighborhood', 'reporting_area', 'census_block_2020',
                       'is_location_redacted', 'has_missing_coordinates', 'has_invalid_coordinates'] %}
        and equal_null(d.{{ col }}, s.{{ col }})
        {% endfor %}
)
select * exclude (source_file, batch_id)
from resolved
qualify row_number() over (
    partition by report_id, offense_id
    order by ingested_at desc, source_file desc nulls last, batch_id desc nulls last, offense_date desc nulls last,
             to_json(array_construct(nibrs_key, offense_category_id, offense_subcategory_id, address_id, police_area_id)) desc
) = 1
{% if is_incremental() %}
except select crime_id, report_id, offense_id, offense_date, ingested_at, nibrs_key,
              offense_category_id, offense_subcategory_id, address_id, police_area_id from {{ this }}
{% endif %}
