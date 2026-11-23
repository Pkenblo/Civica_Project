-- Incluye las variantes de caso y espacios, no solo el texto normalizado.
with expected as (
    select distinct offense_type, offense_type_original
    from {{ ref('stg_arrests') }}
    where offense_type is not null
       or (offense_type_original is not null and upper(trim(offense_type_original)) not in ('', '-'))
)
select e.offense_type, e.offense_type_original
from expected e
left join {{ ref('offense_types') }} t on t.offense_type = e.offense_type
where t.offense_type_id is null
   or t.offense_type is null
   or t.offense_type_id <> {{ dbt_utils.generate_surrogate_key(['e.offense_type']) }}
   or not coalesce(array_contains(to_variant(e.offense_type_original), t.offense_type_original_values), false)
