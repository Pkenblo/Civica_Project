-- La extracción debe apuntar a fragmentos literales y conservar TODO el sufijo descriptivo.
with primary_offsets as (
    select *, position(legal_code in offense_type) + length(legal_code) as primary_end
    from {{ ref('offense_types') }}
),
offsets as (
    select *, case when secondary_legal_code is not null then
                       primary_end + position(secondary_legal_code in substr(offense_type, primary_end)) - 1
                       + length(secondary_legal_code)
                   else primary_end end as description_start
    from primary_offsets
)
select offense_type_id
from offsets
where offense_type is null or offense_type_id is null
   or offense_type_id <> {{ dbt_utils.generate_surrogate_key(['offense_type']) }}
   or (legal_code is not null and position(legal_code in offense_type) = 0)
   or (legal_source is not null and not equal_null(left(offense_type, 3), legal_source))
   or (secondary_legal_code is not null and (
          legal_code is null or secondary_legal_source is null
          or position(secondary_legal_code in substr(offense_type, primary_end)) = 0))
   or (secondary_legal_source is not null
       and position(secondary_legal_source in substr(offense_type, primary_end)) = 0)
   or (external_code is not null
       and not equal_null(external_code, trim(split_part(offense_type, '|', 1))))
   or (offense_description is not null
       and not equal_null(right(offense_type, length(offense_description)), offense_description))
   or (legal_code is not null and (secondary_legal_source is null or secondary_legal_code is not null)
       and not equal_null(offense_description,
               nullif(trim(regexp_replace(trim(substr(offense_type, description_start)), '^[|][[:space:]]*', '')), '')))
   or (parse_status = 'parsed' and (
          offense_description is null or (legal_code is null and external_code is null)
          or (secondary_legal_source is not null and secondary_legal_code is null)))
   or (parse_status = 'administrative' and (
          not equal_null(offense_description, offense_type)
          or legal_source is not null or legal_code is not null
          or secondary_legal_source is not null or secondary_legal_code is not null or external_code is not null))
   or (offense_category is not null and (
          offense_category not in ('ASSAULT', 'DRUGS', 'FIRE', 'KIDNAP/IMPRISON')
          or not regexp_like(offense_description,
                    '^' || offense_category || '[[:space:]]*([-][[:space:]]+|[|][[:space:]]*).+', 's')))
