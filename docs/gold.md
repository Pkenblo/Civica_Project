# Gold de Seattle

Gold publica 13 dimensiones y dos hechos. Incluye además dos puentes `ephemeral` para los consumidores dbt. Consume los 17 modelos [Silver](silver.md) vía `ref()`; no lee Bronze ni los CSV. [Importar el diagrama lógico DBML](../gold_diagram.dbml) en dbdiagram.io.

Los [marts de delitos y licencias](marts.md) consumen `fact_crimes`, `dim_nibrs`, `dim_address`, `dim_postal_codes` y `dim_licenses`. El de tiroteos y homicidios también usa `bridge_crime_shooting_types`. Se construyen en el esquema `MARTS` de la misma base; el comando que selecciona solo `path:models/gold` no los materializa.

## Inventario

| Modelo | Materialización | Clave lógica | Procedencia directa |
|---|---|---|---|
| `dim_date` | table | `date_key` | `crimes`, `reports`, `arrest`, `licenses` |
| `dim_nibrs` | table | `nibrs_key` | `nibrs` |
| `dim_address` | table | `address_id` | `full_address` |
| `dim_postal_codes` | table | `cp` | `postal_codes` |
| `dim_licenses` | incremental | `license_number` | `licenses`, `dim_date` |
| `dim_police_area` | table | `police_area_id` | `police_add` |
| `dim_offense_classification` | table | `offense_classification_id` | `offense_categories`, `offense_subcategories` |
| `dim_shooting_type` | table | `shooting_type_id` | `shooting_types` |
| `dim_arrest_type` | table | `arrest_type_id` | `arrest_types` |
| `dim_agent` | table | `agent_key` | `agents` |
| `dim_subject` | table | `subject_key` | `subject` |
| `dim_cad_profile` | table | `cad_profile_id` | `cad_profiles` |
| `dim_report` | table | `report_id` | `reports` |
| `fact_crimes` | incremental | `crime_id` | `crimes`, `dim_offense_classification`, `dim_report`, `dim_date` |
| `fact_arrests` | incremental | `arrest_number` | `arrest`, `dim_date` |
| `bridge_crime_shooting_types` | ephemeral | `crime_id`, `shooting_type_id` | `crime_shooting_types` |
| `bridge_arrest_offenses` | ephemeral | `arrest_offense_id` | `arrest_offenses` |

### Granos y relaciones

- `fact_crimes` tiene **una fila por delito lógico**, con `crime_id = md5(report_id || '|' || offense_id)` de Silver y `crime_count = 1`. Conserva las referencias a informe, dirección, área policial, NIBRS y clasificación de Seattle (categoría y subcategoría en una sola dimensión). La fecha de ocurrencia proviene de `crimes`; la de reporte, de `reports`. Son dos papeles de `dim_date`, con fecha, clave y timestamp de origen separados. La subcategoría mantiene su categoría padre solo si Silver la conoce.
- `fact_arrests` tiene **una fila por `arrest_number`** con `arrest_count = 1`, fecha de ocurrencia y de registro, y las referencias de Silver a dirección, área, tipo de detención, agente, sujeto, perfil CAD e informe. Edades e indicadores se mantienen en el evento. El dataset incluye más modalidades que detenciones físicas bajo custodia; consultar [la fuente SPD](https://data.seattle.gov/d/9bjs-7a7w).
- No unir directamente los dos hechos por `report_id`: un informe puede tener varios delitos y varias detenciones. Para usar una etiqueta como filtro, usar `EXISTS` contra el puente o contar claves de evento distintas. Los puentes describen asociaciones **observadas**, no necesariamente vigentes; no son hechos adicionales. No existe un catálogo Silver `offense_types`: el puente de arrestos conserva texto legal y descripción publicada, sin inferir el código NIBRS.
- El calendario cubre cada día desde la primera hasta la última fecha de ocurrencia, informe, detención o licencia disponible, incluidas fechas antiguas o años nuevos. Sus límites se recalculan en cada ejecución. `year` es el año natural; `iso_week` y `iso_week_year` deben usarse juntos. `day_of_week` es lunes = 1. No se deduce ninguna fecha de `ingested_at`.
- `dim_address` conserva `cp_status`: `matched` (interior de un único CP), `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Solo `matched` tiene CP. La cartografía de `dim_postal_codes` permanece en `GEOGRAPHY`, con `boundary_version` cuando hay polígono. Los CP son texto; la cobertura de King County no es un filtro municipal de Seattle ni cartografía postal histórica. Una licencia puede declarar un CP válido de formato sin polígono local.

### Incrementalidad

Solo `fact_crimes`, `fact_arrests` y `dim_licenses` usan `delete+insert` por clave y `on_schema_change: fail`: conservan el grano de los tres modelos incrementales de Silver. Las otras dimensiones se reconstruyen como `table`, incluidas las de agentes y sujetos aunque tengan `ingested_at`. `dim_date` también se reconstruye: combina fuentes incrementales y no incrementales para generar un calendario, sin heredar el grano de ninguna.

`fact_crimes`, `fact_arrests` y `dim_licenses` solo admiten filas con `ingested_at` estrictamente mayor que el máximo de su propia tabla Gold. La primera carga y `--full-refresh` no tienen ese corte. Una tabla existente vacía necesita un `--full-refresh` para volver a poblarse. Cambios derivados, como una corrección en `dim_report` que no cambie `crimes.ingested_at`, no reescriben por sí solos las filas de esos tres modelos; para incorporarlos al histórico, usar `--full-refresh`.

Por defecto, los modelos incrementales no comprueban si han desaparecido claves de Silver. Si Silver está completa y quieres retirar de Gold las claves que ya no publica, activa el post-hook solo para esa ejecución y para el modelo afectado. Por ejemplo:

```bash
DBT_GOLD_PRUNE_MISSING_KEYS=1 dbt build --target dev --select fact_crimes
```

Solo el valor `1` activa el borrado. El hook compara contra toda la tabla Silver, no contra el último lote; no recupera altas ni correcciones históricas que queden fuera del corte por `ingested_at`. Las ejecuciones deben ser seriales contra el mismo destino. La limpieza y el `delete+insert` no se publican como una única transacción; si falla el hook, corregir y repetir con la opción activa antes de consumir los resultados.

El CP no se copia en el hecho policial: un cambio de mapa se refleja al reconstruir `dim_address`, sin reescribir los hechos por ese motivo. Al usar `ref('bridge_crime_shooting_types')` o `ref('bridge_arrest_offenses')`, dbt inserta una CTE que lee las asociaciones de Silver. Los puentes no son tablas ni vistas consultables en Gold. Al migrar desde `table`, dbt no elimina las tablas antiguas: antes de retirarlas, revisar consultas externas y volver a desplegar las vistas que aún las referencien.

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

# Desde RAW, después de verificar el mapa activo:
dbt build --target dev --select '+path:models/gold'
```

Las dependencias de transformación se declaran con `ref()`. Las pruebas comprueban unicidad, referencias entre tablas, fechas por papel, recuentos y paridad de hechos y puentes frente a Silver.

## Validación y límites

Se encontraron los tres CSV originales en `Downloads`, no en `Datos_ejemplo/`: 1.571.598 delitos lógicos de 1.571.600 filas, 109.582 detenciones de 144.890 filas y 38.410 números de licencia de 38.413 filas. En licencias se observaron `Cat`, `Dog`, `Goat` y `Pig`. Los archivos no se modificaron ni se subieron. Los CSV y los lotes de Snowflake no son la misma instantánea.

Consultas **de solo lectura** en Snowflake DEV sobre los datos cargados encontraron 1.575.321 parejas informe/delito, 110.143 detenciones y 38.410 licencias, 38.312 de ellas con CP válido y fecha. El mapa tiene 251 CP con geometría; de 156 CP de licencias, 53 no tienen polígono local. Estas cifras no proceden de tablas Gold desplegadas con datos reales.

En la versión anterior pasaron `dbt parse`, `dbt compile` y la comprobación del DAG en el manifiesto. La validación nativa de dbt usó un esquema DEV aislado y datos sintéticos; no validó el build completo con datos reales. El procesamiento asume EPSG:4326 para las coordenadas policiales, sin requerir una variable de confirmación. No se hicieron escrituras en PRE ni PRO.
