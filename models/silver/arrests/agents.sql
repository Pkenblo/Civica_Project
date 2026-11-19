-- Observaciones de agentes: una fila por combinación de ID y atributos publicados.
-- Un agente puede tener varias claves si cambia edad, unidad, cargo u otro atributo.
-- No selecciona un supuesto estado actual ni implementa snapshots o vigencias.

{{ config(materialized='table', database=env_var('DBT_SILVER'), schema='SILVER') }}

with consolidated as (

    {{ consolidate_arrests(ref('stg_arrests')) }}

),

observations as (

    select distinct
          officer_id
        , officer_age
        , officer_gender
        , officer_race
        , officer_squad as squad_description
        , officer_title
    from {{ ref('stg_arrests') }}
    where officer_id is not null

    union

    -- Incluye las combinaciones completadas por la consolidación antes de generar claves.
    select officer_id, officer_age, officer_gender, officer_race, officer_squad, officer_title
    from consolidated
    where officer_id is not null

)

select
      {{ dbt_utils.generate_surrogate_key([
          'officer_id',
          'officer_age',
          'officer_gender',
          'officer_race',
          'squad_description',
          'officer_title'
      ]) }} as agent_key
    , officer_id
    , officer_age
    , officer_gender
    , officer_race
    , squad_description
    , officer_title
from observations
