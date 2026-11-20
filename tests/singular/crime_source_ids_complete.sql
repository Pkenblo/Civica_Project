-- Comprueba cobertura y marca de versión, además de la unicidad probada en YAML.
select md5(report_number) as report_id, offense_id, max(ingested_at) as ingested_at
from {{ ref('stg_crimes') }}
group by report_number, offense_id
minus
select report_id, offense_id, ingested_at from {{ ref('crimes') }}
