-- El inventario del destino debe coincidir con las versiones normalizadas disponibles.
-- Las repeticiones por infracción no suman versiones del hecho.
with scored as (

    {{ arrest_scored_versions(ref('stg_arrests')) }}

),

versions as (

    select distinct arrest_number, ingested_at,
        sha2(to_json(array_construct(
            _row_fingerprint, convert_timezone('UTC', ingested_at)::timestamp_ntz
        )), 256) as version_fingerprint
    from scored

),

expected as (

    select arrest_number, max(ingested_at) as last_ingested_at,
        count(*) as source_version_count,
        sha2(to_json(array_agg(version_fingerprint)
            within group (order by version_fingerprint)), 256) as source_signature
    from versions
    group by arrest_number

)

select expected.arrest_number
from expected
left join {{ ref('arrest') }} as actual on expected.arrest_number = actual.arrest_number
where actual.arrest_number is null
   or not equal_null(actual.last_ingested_at, expected.last_ingested_at)
   or not equal_null(actual.source_signature, expected.source_signature)
   or not equal_null(actual.source_version_count, expected.source_version_count)
