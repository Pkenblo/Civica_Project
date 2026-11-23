# Gold de Seattle

Gold publica 15 dimensiones y dos puentes como vistas, y dos hechos incrementales. Consume los modelos [Silver](silver.md) vía `ref()`; no lee Bronze ni los CSV. [Importar el diagrama lógico DBML](../gold_diagram.dbml) en dbdiagram.io.

Los [marts de delitos y licencias](marts.md) consumen `fact_crimes`, `dim_nibrs`, `dim_address`, `dim_postal_codes` y `dim_licenses`. El de tiroteos y homicidios también usa `bridge_crime_shooting_types`. Se construyen en el esquema `MARTS` de la misma base; el comando que selecciona solo `path:models/gold` no los materializa.

## Inventario

Las [dimensiones](../models/gold/dimensions/) se agrupan por dominio: `arrests`, `crimes`, `geography`, `persons`, `pet_licenses`, `reports` y `socioeconomic`, como en Silver, más `calendar` para `dim_date`. Todas heredan la configuración de vista de `dimensions` en `dbt_project.yml`.

Los YAML de dimensiones comprueban que cada clave lógica sea única y no nula, que el CP asignado a una dirección exista en el catálogo postal, y que la clave de fecha de una licencia coincida con su fecha de emisión. Las pruebas de Silver y las pruebas SQL de Gold se mantienen aparte.

| Modelo | Materialización | Clave lógica | Procedencia directa |
|---|---|---|---|
| `dim_date` | view | `date_key` | Calendario generado |
| `dim_nibrs` | view | `nibrs_key` | `nibrs` |
| `dim_offense_types` | view | `offense_type_id` | `offense_types` |
| `dim_address` | view | `address_id` | `full_address` |
| `dim_postal_codes` | view | `cp` | `postal_codes` |
| `dim_licenses` | view | `license_number` | `licenses`, `dim_date` |
| `dim_police_area` | view | `police_area_id` | `police_add` |
| `dim_offense_classification` | view | `offense_classification_id` | `offense_categories` |
| `dim_shooting_type` | view | `shooting_type_id` | `shooting_types` |
| `dim_arrest_type` | view | `arrest_type_id` | `arrest_types` |
| `dim_agent` | view | `agent_key` | `agents` |
| `dim_subject` | view | `subject_key` | `subject` |
| `dim_cad_profile` | view | `cad_profile_id` | `cad_profiles` |
| `dim_report` | view | `report_id` | `reports` |
| `dim_census_socioeconomic` | view | `cp` | `census_socioeconomic` |
| `fact_crimes` | incremental | `crime_id` | `crimes`, `dim_report`, `dim_date` |
| `fact_arrests` | incremental | `arrest_number` | `arrest`, `dim_date` |
| `bridge_crime_shooting_types` | view | `crime_id`, `shooting_type_id` | `crime_shooting_types` |
| `bridge_arrest_offenses` | view | `arrest_offense_id` | `arrest_offenses` |

### Granos y relaciones

- `fact_crimes` tiene **una fila por delito lógico**, con `crime_id` generado en Silver mediante `dbt_utils.generate_surrogate_key(['report_id', 'offense_id'])` y `crime_count = 1`. Conserva las referencias a informe, dirección, área policial, NIBRS y clasificación de Seattle (categoría y subcategoría en una sola dimensión). La fecha de ocurrencia proviene de `crimes`; la de reporte, de `reports`. Son dos papeles de `dim_date`, con fecha, clave y timestamp de origen separados. La subcategoría mantiene su categoría padre solo si Silver la conoce.
- `fact_arrests` tiene **una fila por `arrest_number`** con `arrest_count = 1`, fecha de ocurrencia y de registro, y las referencias de Silver a dirección, área, tipo de detención, agente, sujeto, perfil CAD e informe. Edades e indicadores se mantienen en el evento. El dataset incluye más modalidades que detenciones físicas bajo custodia; consultar [la fuente SPD](https://data.seattle.gov/d/9bjs-7a7w).
- No unir directamente los dos hechos por `report_id`: un informe puede tener varios delitos y varias detenciones. Para usar una etiqueta como filtro, usar `EXISTS` contra el puente o contar claves de evento distintas. Los puentes describen asociaciones **observadas**, no necesariamente vigentes; no son hechos adicionales. No existe un catálogo Silver `offense_types`: el puente de arrestos conserva texto legal y descripción publicada, sin inferir el código NIBRS.
- El calendario se genera con `dbt_date.get_date_dimension` desde `1900-01-01` hasta `2101-01-01` (fecha final excluida). `year` es el año natural; `iso_week` y `iso_week_year` deben usarse juntos; `day_of_week` es lunes = 1. Los nombres de mes y día siguen abreviados.
- `dim_address` conserva `cp_status`: `matched` (interior de un único CP), `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Solo `matched` tiene CP. La cartografía de `dim_postal_codes` permanece en `GEOGRAPHY`, con `boundary_version` cuando hay polígono. Los CP son texto; la cobertura de King County no es un filtro municipal de Seattle ni cartografía postal histórica. Una licencia puede declarar un CP válido de formato sin polígono local.

### Incrementalidad

`fact_crimes` y `fact_arrests` siguen siendo incrementales: usan `delete+insert` por clave, `on_schema_change: fail` y un bloque `is_incremental()`. Los marts se siguen reconstruyendo como tablas. Las dimensiones y los puentes son vistas consultables en Gold: no almacenan filas ni aplican un corte incremental propio, aunque sus fuentes Silver sean incrementales.

Los dos hechos usan `after_max_ingested_at`: el corte global exige una ingesta estrictamente mayor que el máximo de su propia tabla Gold. La primera carga y `--full-refresh` no tienen ese corte. Una tabla existente vacía necesita un `--full-refresh` para volver a poblarse.

`fact_crimes` incorpora además las filas ya existentes cuya `report_date_time` difiera de la fecha actual de `dim_report`, incluidos cambios a nulo. Así corrige todos los delitos de un informe actualizado aunque solo uno haya recibido una nueva ingesta. Recalcula el timestamp, la fecha y la clave de reporte, pero conserva `crimes.ingested_at`: no usa la ingesta del informe para adelantar artificialmente el cursor del delito. Los demás cambios derivados que queden fuera del corte siguen requiriendo `--full-refresh`.

Por defecto, los modelos incrementales no comprueban si han desaparecido claves de Silver. Los post-hooks de `fact_crimes` y `fact_arrests` permiten retirar las claves que Silver ya no publica, si está completa. Actívalos solo para esa ejecución y para el modelo afectado. Por ejemplo:

```bash
DBT_GOLD_PRUNE_MISSING_KEYS=1 dbt build --target dev --select fact_crimes
```

Solo el valor `1` activa el borrado. El hook compara contra toda la tabla Silver, no contra el último lote; no recupera altas ni correcciones históricas que queden fuera del corte por `ingested_at`. Las ejecuciones deben ser seriales contra el mismo destino. La limpieza y el `delete+insert` no se publican como una única transacción; si falla el hook, corregir y repetir con la opción activa antes de consumir los resultados.

El CP no se copia en el hecho policial: `dim_address` refleja el mapa que publica Silver sin reescribir los hechos por ese motivo. Antes de desplegar la conversión de tablas a vistas, revisar los permisos de reemplazo de los objetos existentes y los permisos de `SELECT` de sus consumidores.

## Ejecución y consultas en DEV

Usar un perfil `default` externo, rol de transformación, lectura de RAW/Silver y permisos de creación en los destinos DEV. `--target` no cambia las variables; comprobar las tres, y no reutilizar el rol o destinos PRE/PRO. El fallback de `DBT_GOLD` a `target.database` permite parsear instalaciones antiguas: al construir Gold, fijar explícitamente la base.

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt deps
dbt parse --target dev
dbt compile --target dev --select 'path:models/gold path:tests/singular/gold'

# Publicar solo las dimensiones y los puentes, con Silver ya publicado:
dbt run --target dev --select path:models/gold/dimensions path:models/gold/bridges

# Con staging y Silver actuales ya publicados:
dbt build --target dev --select 'path:models/gold'
dbt test --target dev --select 'path:models/gold path:tests/singular/gold'

# Desde RAW, después de verificar el mapa activo:
dbt build --target dev --select '+path:models/gold'
```

Las dependencias de transformación se declaran con `ref()`. Las pruebas comprueban unicidad, referencias entre tablas, fechas por papel, recuentos y paridad de hechos y puentes frente a Silver.

## Validación y límites

`python tests/integration/gold_incremental_local_check.py` comprueba en DuckDB las vistas de sujetos, tipos de cargo y calendario. `python tests/integration/gold_report_updates_local_check.py` verifica la vista de informes y la actualización incremental de delitos. Requieren DuckDB, Jinja2, PyYAML y sqlglot; no validan un despliegue en Snowflake.

Se encontraron los tres CSV originales en `Downloads`, no en `Datos_ejemplo/`: 1.571.598 delitos lógicos de 1.571.600 filas, 109.582 detenciones de 144.890 filas y 38.410 números de licencia de 38.413 filas. En licencias se observaron `Cat`, `Dog`, `Goat` y `Pig`. Los archivos no se modificaron ni se subieron. Los CSV y los lotes de Snowflake no son la misma instantánea.

Consultas **de solo lectura** en Snowflake DEV sobre los datos cargados encontraron 1.575.321 parejas informe/delito, 110.143 detenciones y 38.410 licencias, 38.312 de ellas con CP válido y fecha. El mapa tiene 251 CP con geometría; de 156 CP de licencias, 53 no tienen polígono local. Estas cifras no proceden de tablas Gold desplegadas con datos reales.

En la versión anterior pasaron `dbt parse`, `dbt compile` y la comprobación del DAG en el manifiesto. La validación nativa de dbt usó un esquema DEV aislado y datos sintéticos; no validó el build completo con datos reales. El procesamiento asume EPSG:4326 para las coordenadas policiales, sin requerir una variable de confirmación. No se hicieron escrituras en PRE ni PRO.
