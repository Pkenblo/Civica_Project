-- Solo sujetos identificados; no crea una persona ficticia para IDs ausentes.
-- Grano: una combinación observada de identificador y atributos demográficos.
-- Un sujeto puede tener varias claves. No representa un snapshot ni un histórico con vigencias.

{{ config(materialized='incremental', incremental_strategy='delete+insert', unique_key='subject_key', on_schema_change='fail', database=env_var('DBT_SILVER'), schema='SILVER') }}

with consolidated as (

    {{ consolidate_arrests(ref('stg_arrests')) }}

),

observations as (

    select distinct
          subject_id as sk_person
        , subject_gender
        , subject_race
    from {{ ref('stg_arrests') }}
    where subject_id is not null

    union

    select subject_id as sk_person, subject_gender, subject_race
    from consolidated
    where subject_id is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key([
              'sk_person',
              'subject_gender',
              'subject_race'
          ]) }} as subject_key
        , sk_person
        , subject_gender
        , subject_race
    from observations

)

{{ changed_catalog_rows('candidates') }}
