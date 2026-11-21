# Gold de Seattle

Gold publica 14 dimensiones, dos hechos y dos tablas puente reutilizables. Consume los 17 modelos [Silver](silver.md) vía `ref()`; no lee Bronze ni los CSV. [Importar el diagrama DBML](../gold_diagram.dbml) en dbdiagram.io.

## Inventario

| Modelo | Materialización | Clave lógica | Procedencia directa |
|---|---|---|---|
| `dim_date` | table | `date_key` | `crimes`, `reports`, `arrest`, `licenses` |
| `dim_nibrs` | table | `nibrs_key` | `nibrs` |
| `dim_address` | table | `address_id` | `full_address` |
| `dim_postal_codes` | table | `cp` | `postal_codes` |
| `dim_licenses` | incremental | `license_number` | `licenses`, `dim_date` |
| `dim_police_area` | table | `police_area_id` | `police_add` |
| `dim_offense_category` | table | `offense_category_id` | `offense_categories` |
| `dim_offense_subcategory` | table | `offense_subcategory_id` | `offense_subcategories` |
| `dim_shooting_type` | table | `shooting_type_id` | `shooting_types` |
| `dim_arrest_type` | table | `arrest_type_id` | `arrest_types` |
| `dim_agent` | table | `agent_key` | `agents` |
| `dim_subject` | table | `subject_key` | `subject` |
| `dim_cad_profile` | table | `cad_profile_id` | `cad_profiles` |
| `dim_report` | table | `report_id` | `reports` |
| `fact_crimes` | incremental | `crime_id` | `crimes`, `dim_report`, `dim_date` |
| `fact_arrests` | incremental | `arrest_number` | `arrest`, `dim_date` |
| `bridge_crime_shooting_types` | table | `crime_id`, `shooting_type_id` | `crime_shooting_types` |
| `bridge_arrest_offenses` | table | `arrest_offense_id` | `arrest_offenses` |

### Granos y relaciones

- `fact_crimes` tiene **una fila por delito lógico**, con `crime_id = md5(report_id || '|' || offense_id)` de Silver y `crime_count = 1`. Conserva las referencias a informe, dirección, área policial, NIBRS, categoría y subcategoría. La fecha de ocurrencia proviene de `crimes`; la de reporte, de `reports`. Son dos papeles de `dim_date`, con fecha, clave y timestamp de origen separados. La subcategoría mantiene su categoría padre solo si Silver la conoce.
- `fact_arrests` tiene **una fila por `arrest_number`** con `arrest_count = 1`, fecha de ocurrencia y de registro, y las referencias de Silver a dirección, área, tipo de detención, agente, sujeto, perfil CAD e informe. Edades e indicadores se mantienen en el evento. El dataset incluye más modalidades que detenciones físicas bajo custodia; consultar [la fuente SPD](https://data.seattle.gov/d/9bjs-7a7w).
- No unir directamente los dos hechos por `report_id`: un informe puede tener varios delitos y varias detenciones. Para usar una etiqueta como filtro, usar `EXISTS` contra el puente o contar claves de evento distintas. Los puentes describen asociaciones **observadas**, no necesariamente vigentes; no son hechos adicionales. No existe un catálogo Silver `offense_types`: el puente de arrestos conserva texto legal y descripción publicada, sin inferir el código NIBRS.
- El calendario cubre cada día desde la primera hasta la última fecha de ocurrencia, informe, detención o licencia disponible, incluidas fechas antiguas o años nuevos. Sus límites se recalculan en cada ejecución. `year` es el año natural; `iso_week` y `iso_week_year` deben usarse juntos. `day_of_week` es lunes = 1. No se deduce ninguna fecha de `ingested_at`.
- `dim_address` conserva `cp_status`: `matched` (interior de un único CP), `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Solo `matched` tiene CP. La cartografía de `dim_postal_codes` permanece en `GEOGRAPHY`, con `boundary_version` cuando hay polígono. Los CP son texto; la cobertura de King County no es un filtro municipal de Seattle ni cartografía postal histórica. Una licencia puede declarar un CP válido de formato sin polígono local.

### Incrementalidad

Solo `fact_crimes`, `fact_arrests` y `dim_licenses` usan `delete+insert` por clave y `on_schema_change: fail`: conservan el grano de los tres modelos incrementales de Silver. Las otras dimensiones se reconstruyen como `table`, incluidas las de agentes y sujetos aunque tengan `ingested_at`. `dim_date` también se reconstruye: combina fuentes incrementales y no incrementales para generar un calendario, sin heredar el grano de ninguna.

Gold compara la fila completa con `EXCEPT` y sustituye solo las altas y versiones distintas, incluidos cambios a `NULL`. No aplica un máximo global de `ingested_at`: así una corrección tardía o una fecha de informe actualizada puede reflejarse sin nueva ingesta del hecho. La comparación puede releer todo Silver y Gold: ahorra **escrituras**, no necesariamente lecturas.

En los modelos incrementales, un post-hook elimina las claves que desaparecen de la relación Silver publicada; no infiere borrados del origen a partir de ficheros diferenciales. Las ejecuciones deben ser seriales contra el mismo destino. La limpieza y el `delete+insert` no se publican como una única transacción; si falla un hook, corregir y volver a ejecutar antes de consumir los resultados. No lanzar esta reconciliación contra Silver incompleto ni migrar esquemas con `--full-refresh` sin revisar el histórico y los destinos.

El CP no se copia en el hecho policial: un cambio de mapa se refleja al reconstruir `dim_address`, sin reescribir los hechos por ese motivo. Los puentes se reconstruyen desde las asociaciones observadas en Silver.

## Ejecución y consultas en DEV

Usar un perfil `default` externo, rol de transformación, lectura de RAW/Silver y permisos de creación en los destinos DEV. `--target` no cambia las variables; comprobar las tres, y no reutilizar el rol o destinos PRE/PRO. El fallback de `DBT_GOLD` a `target.database` permite parsear instalaciones antiguas: al construir Gold, fijar explícitamente la base.

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt deps
dbt parse --target dev
dbt compile --target dev --select 'path:models/gold path:tests/singular/gold'

# Con staging y Silver actuales ya publicados:
dbt build --target dev --select 'path:models/gold'
dbt test --target dev --select 'path:models/gold path:tests/singular/gold'

# Desde RAW, solo después de verificar el mapa activo y documentar el CRS policial:
dbt build --target dev --select '+path:models/gold' --vars '{police_coordinates_epsg4326_confirmed: true}'
```

Las dependencias de transformación se declaran con `ref()`. Las pruebas comprueban unicidad, referencias entre tablas, fechas por papel, recuentos y paridad de hechos y puentes frente a Silver.

## Validación y límites

Se encontraron los tres CSV originales en `Downloads`, no en `Datos_ejemplo/`: 1.571.598 delitos lógicos de 1.571.600 filas, 109.582 detenciones de 144.890 filas y 38.410 números de licencia de 38.413 filas. En licencias se observaron `Cat`, `Dog`, `Goat` y `Pig`. Los archivos no se modificaron ni se subieron. Los CSV y los lotes de Snowflake no son la misma instantánea.

Consultas **de solo lectura** en Snowflake DEV sobre los datos cargados encontraron 1.575.321 parejas informe/delito, 110.143 detenciones y 38.410 licencias, 38.312 de ellas con CP válido y fecha. El mapa tiene 251 CP con geometría; de 156 CP de licencias, 53 no tienen polígono local. Estas cifras no proceden de tablas Gold desplegadas con datos reales.

Pasaron `dbt parse`, `dbt compile` y la comprobación del DAG en el manifiesto. El analizador DBML aceptó las 18 tablas y sus 24 relaciones. La validación nativa de dbt usó un esquema DEV aislado y datos sintéticos; no validó el build completo con datos reales. No se hicieron escrituras en PRE ni PRO.
