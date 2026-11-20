# Silver de Seattle

Los cuatro modelos `stg_*` leen las fuentes Bronze. La cuarta fuente se llama `brz_zipcode_areas.zipcode_areas` en el proyecto. Silver se publica en `DBT_SILVER.SILVER` y no añade fuentes ni macros.

| Modelo | Materialización | Clave primaria | Qué representa |
|---|---|---|---|
| `arrest` | incremental | `arrest_number` | Detención, informe, personas, edades en el evento, área, dirección, CAD e indicadores |
| `arrest_offenses` | table | `arrest_offense_id` | Asociación observada de detención, texto legal y descripción NIBRS |
| `arrest_types` | table | `arrest_type_id` | Tipo de actuación |
| `cad_profiles` | table | `cad_profile_id` | Cierre, tipo inicial y prioridad CAD, incluso parciales |
| `crimes` | incremental | `crime_id` | Delito dentro de un informe |
| `crime_shooting_types` | table | `(crime_id, shooting_type_id)` | Etiqueta de tiroteo observada en un delito |
| `nibrs` | table | `nibrs_key` | Última clasificación recibida por código NIBRS |
| `offense_categories` | table | `offense_category_id` | Categoría del origen |
| `offense_subcategories` | table | `offense_subcategory_id` | Etiqueta en el contexto de su categoría |
| `shooting_types` | table | `shooting_type_id` | Etiqueta informada; staging convierte `-` en `NULL` |
| `full_address` | table | `address_id` | Bloque, coordenadas, barrio, área de reporte, bloque censal, CP y `cp_status` |
| `police_add` | table | `police_area_id` | Combinación de distrito, sector y beat |
| `postal_codes` | table | `cp` | CP del mapa activo o CP válido de licencia; una geometría como máximo |
| `agents` | table | `agent_key` | Último perfil por `officer_id` |
| `subject` | table | `subject_key` | Último perfil por `sk_person` |
| `reports` | table | `report_id` | Informe de delitos o detenciones; fecha tomada solo de delitos |
| `licenses` | incremental | `license_number` | Licencia y CP de origen |

## Claves y asociaciones

`report_id = md5(report_number)` usa el número común de staging, que conserva los ceros. `crime_id = md5(report_id || '|' || offense_id)` identifica una pareja; `report_id` tiene longitud fija. La fecha del informe se consulta en `reports`. Compartir informe no dice qué detención corresponde a qué delito. Las FK de clasificación son opcionales: se conserva la categoría aunque falte la subcategoría y se comprueba que ambas referencias concuerden. NIBRS se resuelve por código, independientemente de esa jerarquía.

En los CSV completos, **1.575.312 filas de delitos dan 1.575.310 parejas**. Las dos parejas repetidas solo difieren en la etiqueta de tiroteo. El puente lee todas las etiquetas de staging, no la fila ganadora del hecho. Las 145.625 filas de detenciones dan 110.143 detenciones; una tiene 11 cargos. En 71 filas faltan tanto el tipo como la descripción: se conserva la detención sin inventar un cargo. No se necesita `offense_types`: el tipo es un texto atómico sin atributos propios; 521 textos legales se observan con más de una descripción NIBRS. Esa descripción se conserva como dato del cargo, sin inferir un código.

Los ficheros diferenciales documentados no incluyen identificador de cargo, bajas ni garantía de contener todas las etiquetas de una entidad. Los dos puentes representan **asociaciones observadas**, no relaciones necesariamente vigentes. Un nuevo fichero puede aportar un cargo o etiqueta sin repetir los anteriores. Distinguir una retirada de una omisión exigiría bajas explícitas o instantáneas completas identificadas como tales.

Los perfiles personales cambian sin que cambie la clave: se elige la última observación de cada ID, no una persona por fila de detención. Los catálogos de etiquetas y combinaciones se reconstruyen desde staging; los de identificador estable (personas y códigos NIBRS) eligen una sola fila completa por ID. Las claves compuestas de catálogo usan arrays en orden fijo antes del hash: un separador dentro de una descripción no desplaza los límites entre campos.

## Versiones y datos tardíos

Los tres hechos usan `delete+insert`, `on_schema_change='fail'` y `row_number()`. `_INGESTED_AT` pasa sin conversión desde RAW; ni el lote ni la fecha del evento son el cursor. En incremental se admiten claves ausentes y filas con `ingested_at >=` la fecha **de su propia clave**. Un máximo global omitiría tanto altas tardías como correcciones más recientes para una clave, pero anteriores al máximo de otra. Se releen empates y `EXCEPT` evita escribir ganadores idénticos. El ahorro está en las escrituras; no se presupone que Snowflake pueda podar todo el histórico de lectura. RAW debe conservar las versiones y no propagar borrados físicos.

La fila más reciente gana entera, también cuando trae `NULL`. En empates se aplican los criterios explícitos de cada SQL (fecha de expedición en licencias, procedencia y contenido). El orden es reproducible, no demuestra qué fila se editó primero. No se observan claves de hecho ausentes en los CSV; las filas sin clave o sin ingesta permanecen en RAW/staging y los tests las señalan. Para `offense_id` presente en varios informes hay un aviso: el [análisis previo de RAW](informe_grano_seattle.md) documenta `71157844528` en dos informes, mientras que el CSV solo contiene uno. Sin evidencia de baja no se borra ninguna pareja.

Las 38.413 filas de licencias dan 38.410 números y 38.410 valores distintos de `md5(license_number || '|' || coalesce(animal_name, ''))`. Un cambio de nombre sustituye `license_id`, no crea otra licencia. Se valida que el número no contenga el separador. Los CP que no tengan cinco dígitos quedan nulos; no se completan los cortos por suposición.

## Ejecución en DEV

Configurar el perfil `default`, `DBT_BRONZE` y `DBT_SILVER` para el mismo entorno; `--target` no cambia esas variables. `generate_schema_name` usa los esquemas configurados sin prefijo. Antes de escribir sobre una instalación anterior, comparar tablas y consumidores, comprobar el histórico RAW y planificar la migración. El cambio de nombre `licencia` → `licenses` no borra la tabla antigua.

`postal_codes` valida la versión activa y disuelve las piezas por CP (273 entidades, 251 CP en el GeoJSON de referencia). Para otro mapa, configurar `zipcode_boundary_version` y `zipcode_expected_feature_count` juntos. Los CP de licencias fuera de cobertura no necesitan polígono. `full_address` exige confirmación documental del CRS **policial**. Asigna CP únicamente en el interior de una sola zona; distingue límite, solape, falta de cobertura y ubicación ocultada, ausente o inválida. Al cambiar el mapa, reconstruir ambos modelos: el CP no forma parte de `address_id`.

```bash
dbt deps
dbt parse --target dev
# Solo tras verificar destinos, mapa y CRS policial:
dbt build --target dev --vars '{police_coordinates_epsg4326_confirmed: true}'
```

La [regresión con datos sintéticos](../tests/integration/arrest_delete_insert_check.py) crea un esquema DEV propio y comprueba los tres incrementales, catálogos y puentes. En este checkout se comprobó el DAG y se ejercitaron los dos caminos SQL sin conexión, con datos de ejemplo y cambios sintéticos. Falta la ejecución nativa: el entorno de implementación no tenía perfil DEV ni conexión JWT configurados. Los resultados locales no certifican la geometría esférica ni la materialización de Snowflake.
