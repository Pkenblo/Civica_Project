{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='offense_type_id',
    on_schema_change='fail'
) }}

{% set code_pattern = '[0-9]{1,3}[A-Z]?([.]([0-9]{1,4}[A-Z]{0,2}|[A-Z]{1,2}[0-9]?))+([(][0-9A-Z]{1,4}[)])*' %}
{% set source_pattern = '^(RCW|SMC)[[:space:]]*([-][[:space:]]*)*' %}

-- La identidad es el texto completo de staging, no el código ni los componentes.
with candidates as (
    select s.*
    from {{ ref('stg_arrests') }} s
    where s.offense_type is not null and s.ingested_at is not null
    {% if is_incremental() %}
      and {{ after_max_ingested_at('s.ingested_at') }}
    {% endif %}
),
originals as (
    -- Solo para los tipos del lote, recuperar también sus variantes históricas.
    select s.offense_type,
           array_agg(distinct s.offense_type_original) within group (order by s.offense_type_original) as offense_type_original_values
    from {{ ref('stg_arrests') }} s
    join (select distinct offense_type from candidates) c on c.offense_type = s.offense_type
    group by s.offense_type
),
latest as (
    select offense_type, ingested_at
    from candidates
    qualify row_number() over (
        partition by offense_type
        order by ingested_at desc nulls last, source_file desc nulls last, batch_id desc nulls last,
                 offense_type_original desc nulls last
    ) = 1
),
prefixes as (
    select l.*, o.offense_type_original_values,
           case when regexp_like(l.offense_type, '^(RCW|SMC)([[:space:]]|[-]).*', 's')
                then left(l.offense_type, 3) end as legal_source,
           case when position('|' in l.offense_type) > 0
                     and regexp_like(trim(split_part(l.offense_type, '|', 1)), '^[0-9]+$')
                then trim(split_part(l.offense_type, '|', 1)) end as external_code
    from latest l
    join originals o on o.offense_type = l.offense_type
),
payloads as (
    select *,
           case when legal_source is not null then regexp_replace(offense_type, '{{ source_pattern }}', '')
                when external_code is not null then trim(substr(offense_type, position('|' in offense_type) + 1))
                else offense_type end as source_payload
    from prefixes
),
primary_inputs as (
    -- SMC - SMC11.22.080.B6 contiene el código literal; no se reescribe su contenido.
    select *, case when left(source_payload, 3) = legal_source
                        and regexp_like(source_payload, '^(RCW|SMC)[0-9].*', 's')
                   then substr(source_payload, 4) else source_payload end as primary_payload
    from payloads
),
primary_candidates as (
    select *, case when legal_source is not null or external_code is not null
                   then regexp_substr(primary_payload, '^{{ code_pattern }}') end as primary_candidate
    from primary_inputs
),
primary_tails as (
    select *, substr(primary_payload, length(primary_candidate) + 1) as primary_tail
    from primary_candidates
),
primary_references as (
    select *, case when primary_candidate is not null
                        and (primary_tail = '' or regexp_like(primary_tail, '^([[:space:]]|[|]).*', 's'))
                   then primary_candidate ||
                        case when regexp_like(primary_tail, '^[[:space:]]+[A-Z][[:space:]]*[|].*', 's')
                             then regexp_substr(primary_tail, '^[[:space:]]+[A-Z]') else '' end
              end as legal_code
    from primary_tails
),
primary_descriptions as (
    select *, nullif(trim(
           case when legal_code is not null then
                    regexp_replace(trim(substr(primary_payload, length(legal_code) + 1)), '^[|][[:space:]]*', '')
                when legal_source is not null and position('|' in offense_type) > 0 then
                    substr(offense_type, position('|' in offense_type) + 1)
                else primary_payload end), '') as primary_description
    from primary_references
),
secondary_inputs as (
    select *, case when legal_code is not null
                        and regexp_like(primary_description, '^(RCW|SMC)([[:space:]]|[-]).*', 's')
                   then left(primary_description, 3) end as secondary_legal_source,
           regexp_replace(primary_description, '{{ source_pattern }}', '') as secondary_payload
    from primary_descriptions
),
secondary_candidates as (
    select *, case when secondary_legal_source is not null
                   then regexp_substr(secondary_payload, '^{{ code_pattern }}') end as secondary_candidate
    from secondary_inputs
),
secondary_tails as (
    select *, substr(secondary_payload, length(secondary_candidate) + 1) as secondary_tail
    from secondary_candidates
),
secondary_references as (
    select *, case when secondary_candidate is not null
                        and (secondary_tail = '' or regexp_like(secondary_tail, '^([[:space:]]|[|]).*', 's'))
                   then secondary_candidate ||
                        case when regexp_like(secondary_tail, '^[[:space:]]+[A-Z][[:space:]]*[|].*', 's')
                             then regexp_substr(secondary_tail, '^[[:space:]]+[A-Z]') else '' end
              end as secondary_legal_code
    from secondary_tails
),
descriptions as (
    -- Se retiene el sufijo completo: barras, guiones, calificadores y segmentos anidados.
    select *, case when secondary_legal_code is not null then
                    nullif(trim(regexp_replace(trim(substr(secondary_payload, length(secondary_legal_code) + 1)),
                                              '^[|][[:space:]]*', '')), '')
                   else primary_description end as offense_description
    from secondary_references
),
classified as (
    select *, case
               when offense_type in ('OUTSIDE AGENCY -- FELONY WARRANT', 'OUTSIDE AGENCY -- MISDEMEANOR WARRANT',
                                     'DOC DETAINER') then 'administrative'
               when legal_code is not null and offense_description is not null
                    and (secondary_legal_source is null or secondary_legal_code is not null)
                    and not regexp_like(offense_description, '^(RCW|SMC)([[:space:]]|[-]).*', 's') then 'parsed'
               when external_code is not null and primary_candidate is null
                    and regexp_count(offense_type, '[|]') = 1 and offense_description is not null then 'parsed'
               else 'review_required' end as parse_status,
           -- Solo familias explícitas revisadas en los 728 valores; no es una jerarquía NIBRS.
           case when regexp_like(offense_description,
                                '^(ASSAULT|DRUGS|FIRE|KIDNAP/IMPRISON)[[:space:]]+-[[:space:]]+.+', 's')
                then regexp_substr(offense_description, '^(ASSAULT|DRUGS|FIRE|KIDNAP/IMPRISON)')
                when regexp_like(offense_description, '^DRUGS[[:space:]]*[|].+', 's') then 'DRUGS'
           end as offense_category
    from descriptions
)
select {{ dbt_utils.generate_surrogate_key(['offense_type']) }} as offense_type_id, offense_type, offense_type_original_values,
       legal_source, legal_code, secondary_legal_source, secondary_legal_code, external_code,
       offense_description, offense_category, parse_status, ingested_at
from classified
