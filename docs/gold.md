# Gold de Seattle

Gold publica dos hechos reutilizables y compara **delitos ocurridos** con **licencias expedidas** por CP y año natural. Consume los 17 modelos [Silver](silver.md) vía `ref()`; no lee Bronze ni los CSV. La relación de los marts es territorial, no individual. [Importar el diagrama DBML](../gold_diagram.dbml) en dbdiagram.io.

## Inventario

| Modelo | Materialización | Clave lógica | Procedencia directa |
|---|---|---|---|
| `dim_date` | incremental | `date_key` | `crimes`, `reports`, `arrest`, `licenses` |
| `dim_nibrs` | incremental | `nibrs_key` | `nibrs`, seed `nibrs_severity_map` |
| `dim_address` | incremental | `address_id` | `full_address` |
| `dim_postal_codes` | incremental | `cp` | `postal_codes` |
| `dim_licenses` | incremental | `license_number` | `licenses`, `dim_date` |
| `dim_police_area` | incremental | `police_area_id` | `police_add` |
| `dim_offense_category` | incremental | `offense_category_id` | `offense_categories` |
| `dim_offense_subcategory` | incremental | `offense_subcategory_id` | `offense_subcategories` |
| `dim_shooting_type` | incremental | `shooting_type_id` | `shooting_types` |
| `dim_arrest_type` | incremental | `arrest_type_id` | `arrest_types` |
| `dim_agent` | incremental | `agent_key` | `agents` |
| `dim_subject` | incremental | `subject_key` | `subject` |
| `dim_cad_profile` | incremental | `cad_profile_id` | `cad_profiles` |
| `dim_report` | incremental | `report_id` | `reports` |
| `fact_crimes` | incremental | `crime_id` | `crimes`, `dim_report`, `dim_date` |
| `fact_arrests` | incremental | `arrest_number` | `arrest`, `dim_date` |
| `bridge_crime_shooting_types` | table | `crime_id`, `shooting_type_id` | `crime_shooting_types` |
| `bridge_arrest_offenses` | table | `arrest_offense_id` | `arrest_offenses` |
| `mart_cp_crimes_pets` | table | `cp`, `year` | `fact_crimes`, `dim_address`, `dim_date`, `dim_licenses`, `dim_postal_codes` |
| `mart_cp_crimes_pets_severity` | table | `cp`, `year` | primer mart, `fact_crimes`, `dim_address`, `dim_date`, `dim_nibrs` |

### Granos y relaciones

- `fact_crimes` tiene **una fila por delito lógico**, con `crime_id = md5(report_id || '|' || offense_id)` de Silver y `crime_count = 1`. Conserva las referencias a informe, dirección, área policial, NIBRS, categoría y subcategoría. La fecha de ocurrencia proviene de `crimes`; la de reporte, de `reports`. Son dos papeles de `dim_date`, con fecha, clave y timestamp de origen separados. La subcategoría mantiene su categoría padre solo si Silver la conoce.
- `fact_arrests` tiene **una fila por `arrest_number`** con `arrest_count = 1`, fecha de ocurrencia y de registro, y las referencias de Silver a dirección, área, tipo de detención, agente, sujeto, perfil CAD e informe. Edades e indicadores se mantienen en el evento. El dataset incluye más modalidades que detenciones físicas bajo custodia; consultar [la fuente SPD](https://data.seattle.gov/d/9bjs-7a7w).
- No unir directamente los dos hechos por `report_id`: un informe puede tener varios delitos y varias detenciones. Para usar una etiqueta como filtro, usar `EXISTS` contra el puente o contar claves de evento distintas. Los puentes describen asociaciones **observadas**, no necesariamente vigentes; no son hechos adicionales. No existe un catálogo Silver `offense_types`: el puente de arrestos conserva texto legal y descripción publicada, sin inferir el código NIBRS.
- El calendario cubre cada día desde la primera hasta la última fecha de ocurrencia, informe, detención o licencia disponible, incluidas fechas antiguas o años nuevos. Mantiene días ya publicados incluso si dejan de estar referenciados. `year` es el año natural; `iso_week` y `iso_week_year` deben usarse juntos. `day_of_week` es lunes = 1. No se deduce ninguna fecha de `ingested_at`.
- `dim_address` conserva `cp_status`: `matched` (interior de un único CP), `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Solo `matched` tiene CP. La cartografía de `dim_postal_codes` permanece en `GEOGRAPHY`, con `boundary_version` cuando hay polígono. Los CP son texto; la cobertura de King County no es un filtro municipal de Seattle ni cartografía postal histórica. Una licencia puede declarar un CP válido de formato sin polígono local.

### Incrementalidad

Las 14 dimensiones y los dos hechos usan `delete+insert` por su clave y `on_schema_change: fail`. No se deduplica de nuevo un hecho que Silver ya consolidó con `QUALIFY ROW_NUMBER()`; se prueba su grano y su equivalencia con Silver. Gold compara la fila completa con `EXCEPT` y sustituye solo las altas y versiones distintas, incluidos cambios a `NULL`. El CP cartográfico compara el binario WKB y su versión sin convertir el tipo almacenado. No se usa un máximo global de `ingested_at`: una corrección tardía, una modificación de `reports` o de la seed, o una nueva asignación en `full_address` no requiere que cambie la ingesta del hecho.

La comparación puede releer todo Silver y Gold: se ahorran **escrituras**, no necesariamente lecturas. Un post-hook sencillo elimina las claves que desaparecen de la relación Silver publicada (excepto días del calendario); no infiere borrados del origen a partir de ficheros diferenciales. Las ejecuciones deben ser seriales contra el mismo destino. La limpieza y el `delete+insert` no se publican como una única transacción; si falla un hook, corregir y volver a ejecutar antes de consumir los resultados. No lanzar esta reconciliación contra Silver incompleto ni migrar esquemas con `--full-refresh` sin revisar el histórico y los destinos.

El CP no se copia en el hecho policial: cambiar el mapa actualiza `dim_address` y los marts al reconstruirlos, sin reescribir delitos no afectados en sus atributos. Puentes y marts se reconstruyen para reemplazar correctamente agregados de CP/año que dejen de existir, sin cursores o débitos de recuento.

## Métricas y clasificación

En `mart_cp_crimes_pets` se agregan por separado los delitos (CP de `dim_address`, año de ocurrencia) y las licencias (CP declarado por el propietario, año de expedición). Solo después se hace una unión exterior completa. El modelo conserva los grupos presentes en una sola fuente; cero significa **ningún registro observado**, no que se haya medido ausencia del fenómeno. No crea pares sin datos de ninguna fuente ni CP ficticios. Los eventos sin CP o sin fecha se conservan aguas arriba, pero no tienen una fila imputada en estos marts; el [diagnóstico de cobertura](../analyses/gold_coverage.sql) los cuantifica.

`total_licenses_issued` cuenta una vez la versión publicada de cada `license_number`. El `license_id` de Silver depende del nombre del animal y se conserva como atributo, no como clave. `species` conserva el valor Silver; `species_group` normaliza mayúsculas/espacios y separa perro, gato, otras especies informadas y desconocidas. Los cuatro recuentos suman el total. Son **expediciones publicadas**: no identifican animales únicos, no prueban vigencia y la última versión no reconstruye renovaciones ni inventa bajas. `has_crime_records`, `has_license_records` y `has_geography` distinguen disponibilidad observada y cartografía. `crimes_per_1000_licenses_issued` es una ratio descriptiva, nula si el denominador es cero, nunca una tasa poblacional o de riesgo.

El segundo mart conserva las filas y métricas del primero. `serious_crimes + minor_crimes + unclassified_crimes = total_crimes`. Los porcentajes de graves y leves dividen por **graves + leves** y quedan nulos sin clasificados; `pct_severity_coverage` divide por **todos los delitos**, incluido el grupo desconocido, y es nulo si no hay delitos. Comparar porcentajes entre zonas solo junto a cobertura y volumen.

### Reglas de gravedad analítica

No es una clasificación penal oficial ni una traducción de Group A/B. Se revisaron códigos, descripciones y frecuencias de los CSV originales disponibles localmente, y las definiciones [NIBRS del FBI](https://www.fbi.gov/services/cjis/ucr/nibrs). La [seed](../seeds/nibrs_severity_map.csv) contiene una justificación por código:

- `grave`: el código implica por su definición homicidio doloso/no negligente, privación coercitiva de libertad, determinadas agresiones sexuales, robo con fuerza o amenaza, agresión agravada o trata. No se infiere el resultado jurídico del caso.
- `leve`: códigos seleccionados en los que la rúbrica no implica violencia ni daño directo (toque de queda/permanencia/vagancia, y embriaguez sin conducción). Esto no es un juicio por expediente.
- `sin_clasificar`: código ausente, nuevo o sin regla. Por ejemplo: `23F` (hurto en vehículo), `90Z` (otros), `220` (allanamiento/robo con entrada), `290` (daños), `13B` (agresión simple) y `999` (no reportable). Las rúbricas amplias no aportan por sí solas datos suficientes sobre cuantía, contexto o daño. Tampoco se clasifica homicidio justificado como delito grave por el nombre.

`gold_unmapped_nibrs` emite una advertencia automática por cada código sin regla (no utilizar `--warn-error` en una ejecución normal que acepte esta cobertura). El análisis de cobertura lista los códigos pendientes ponderados por volumen e incluye el código no informado. Para mejorar cobertura, priorizar los códigos pendientes de mayor volumen y acordar con especialistas una rúbrica reproducible gracias a atributos adicionales sobre daño, amenaza o cuantía, o mantenerlos sin clasificar. Para cambiar una regla, revisar el efecto, editar la seed bajo control de versiones y ejecutar Gold de nuevo: la regla vigente se aplica a todo el histórico, sin versionado temporal dentro del mart.

## Ejecución y consultas en DEV

Usar un perfil `default` externo, rol de transformación, lectura de RAW/Silver y permisos de creación en los destinos DEV. `--target` no cambia las variables; comprobar las tres, y no reutilizar el rol o destinos PRE/PRO. El fallback de `DBT_GOLD` a `target.database` permite parsear instalaciones antiguas: al construir Gold, fijar explícitamente la base.

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt deps
dbt parse --target dev
dbt compile --target dev --select 'path:models/gold nibrs_severity_map path:tests/singular/gold resource_type:analysis'

# Con staging y Silver actuales ya publicados:
dbt build --target dev --select 'path:models/gold nibrs_severity_map'
dbt test --target dev --select 'path:models/gold nibrs_severity_map path:tests/singular/gold'

# Desde RAW, solo después de verificar el mapa activo y documentar el CRS policial:
dbt build --target dev --select '+path:models/gold' --vars '{police_coordinates_epsg4326_confirmed: true}'
```

Las relaciones esperadas de DIM → hechos → marts se comprueban por `ref()` cuando hay dependencias de transformación y con tests de FK para las referencias conservadas de Silver. Las pruebas incluyen unicidad, fechas por papel, recuentos y datos frente a Silver, paridad de ambos puentes, desgloses, porcentajes y reconciliación independiente por CP y año. Ejecutar los SQL compilados de [`gold_cp_comparisons.sql`](../analyses/gold_cp_comparisons.sql) y [`gold_coverage.sql`](../analyses/gold_coverage.sql) en Snowflake: rankings, comparación, evolución, `CORR()`, cobertura y códigos pendientes. La correlación de ejemplo se calcula por año, solo con polígono y registros de ambas fuentes; informa el número de CP usados. Para comprobar el efecto de esta selección, repetir con otro universo definido y reportarlo por separado.

## Validación y límites

Se encontraron los tres CSV originales en `Downloads`, no en `Datos_ejemplo/`: 1.571.598 delitos lógicos de 1.571.600 filas, 109.582 detenciones de 144.890 filas y 38.410 números de licencia de 38.413 filas. En licencias se observaron `Cat`, `Dog`, `Goat` y `Pig`. Los archivos no se modificaron ni se subieron. Los CSV y los lotes de Snowflake no son la misma instantánea.

Consultas **de solo lectura** en Snowflake DEV sobre los datos cargados: 1.575.321 parejas informe/delito, 110.143 detenciones y 38.410 licencias, 38.312 de ellas con CP válido y fecha. La regla clasifica 86.146 delitos como graves y 972 como leves: **5,53 % clasificado**, con 1.488.203 sin clasificar. El mapa tiene 251 CP con geometría; de 156 CP de licencias, 53 no tienen polígono local. La prueba espacial exploratoria, **bajo el supuesto EPSG:4326**, asignó CP a 1.172.241 delitos (74,41 %) en 39 CP y clasificó el 4,98 % de esos delitos. Para 2025, el cruce exploratorio arrojó Pearson `r = 0,6427` en 33 CP con ambas fuentes. Estas cifras no proceden de tablas Gold desplegadas con datos reales.

Pasaron `dbt parse`, `dbt compile` y la comprobación del DAG en el manifiesto. El analizador DBML aceptó las 18 tablas y sus 24 relaciones. La validación nativa de dbt usó un esquema DEV aislado y datos sintéticos. No se habilitó el cruce de datos reales: los metadatos de SPD describen coordenadas aproximadas al bloque pero no confirmaron el CRS, y el esquema Silver actual aún no estaba publicado en DEV. No se hicieron escrituras en PRE ni PRO.

No interpretar correlación como causalidad. Población y superficie distintas, densidad comercial o residencial, censura o aproximación de puntos, falta de CP, sesgo de registro y vigencia desconocida de licencias, años incompletos y muestras pequeñas pueden cambiar el resultado. La fuente tiene mucha más cobertura de expediciones en los últimos años; no comparar una parte de un año con un año completo sin alinear la ventana. No hay denominadores de población ni vigencias de licencias integrados. Tampoco se enlazan domicilios o personas con incidentes.
