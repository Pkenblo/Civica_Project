-- Una fila por categoría informada de un delito.
{{ config(materialized='incremental', incremental_strategy='delete+insert', unique_key='offense_category_id', on_schema_change='fail', database=env_var('DBT_SILVER'), schema='SILVER') }}

with categories as (

    select distinct offense_category
    from {{ ref('stg_crimes') }}
    where offense_id is not null
      and offense_category is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key(['offense_category']) }} as offense_category_id
        , offense_category
    from categories

)

select * from candidates
{% if is_incremental() %}
where offense_category_id in (
    select offense_category_id
    from (
        select * from candidates
        except
        select offense_category_id, offense_category
        from {{ this }}
    ) as differences
)
{% endif %}
