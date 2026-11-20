-- La misma etiqueta bajo dos categorías representa dos subcategorías distintas.
{{ config(materialized='incremental', incremental_strategy='delete+insert', unique_key='offense_subcategory_id', on_schema_change='fail', database=env_var('DBT_SILVER'), schema='SILVER') }}

with subcategories as (

    select distinct offense_category, offense_sub_category
    from {{ ref('stg_crimes') }}
    where offense_id is not null
      and offense_sub_category is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key([
              'categories.offense_category_id', 'subcategories.offense_sub_category'
          ]) }} as offense_subcategory_id
        , categories.offense_category_id
        , subcategories.offense_sub_category
    from subcategories
    left join {{ ref('offense_categories') }} as categories
        on subcategories.offense_category = categories.offense_category

)

select * from candidates
{% if is_incremental() %}
where offense_subcategory_id in (
    select offense_subcategory_id
    from (
        select * from candidates
        except
        select offense_subcategory_id, offense_category_id, offense_sub_category
        from {{ this }}
    ) as differences
)
{% endif %}
