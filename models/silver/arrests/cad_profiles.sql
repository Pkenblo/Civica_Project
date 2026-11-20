-- Una fila por combinación CAD publicada en arrest; no identifica llamadas individuales.
{{ config(materialized='incremental', incremental_strategy='delete+insert', unique_key='cad_profile_id', on_schema_change='fail', database=env_var('DBT_SILVER'), schema='SILVER') }}

with candidates as (

    select distinct
          cad_profile_id
        , nullif(consolidation_choices:cad_clearance, parse_json('null'))::varchar as cad_clearance
        , nullif(consolidation_choices:cad_initial_call_type, parse_json('null'))::varchar as cad_initial_call_type
        , nullif(consolidation_choices:cad_priority, parse_json('null'))::number(38, 0) as cad_priority
    from {{ ref('arrest') }}
    where cad_profile_id is not null

)

{{ changed_catalog_rows('candidates') }}
