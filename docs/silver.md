# Silver de Seattle: implementación y decisiones

Silver normaliza el modelo de negocio de Seattle para que Gold pueda contar delitos, detenciones y licencias sin que las versiones ni las asociaciones multipliquen los resultados. Esta guía describe el código vigente en [`models/silver/`](../models/silver/). El [diagrama definitivo](silver_diagram.svg) y su [diccionario y DBML editable](silver_diagram.md) representan ese mismo esquema; no certifican su despliegue.

## De Bronze a Silver

- **Bronze (`DBT_BRONZE.RAW`)** declara `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. La carga es externa a dbt; RAW conserva el valor original, las versiones y la procedencia. Los CSV de análisis no son fuentes dbt.
- **Staging (`DBT_BRONZE.STG`)** publica cuatro vistas: `stg_crimes`, `stg_arrests`, `stg_pet_licenses` y `stg_zipcode_areas`. Renombra y tipa, recorta espacios y normaliza textos descriptivos, códigos, vacíos y marcadores según el campo. Solo `arrest_type` unifica además los espacios internos. No se cambia el caso de los identificadores ni de la procedencia y no se deduplican filas. Las fechas del evento policial son `TIMESTAMP_NTZ`; `_INGESTED_AT` llega sin conversión como `ingested_at` (`TIMESTAMP_LTZ`), junto a `source_file` y `batch_id`.
- **Silver (`DBT_SILVER.SILVER`)** fija el grano, elige versiones, separa los catálogos y las asociaciones múltiples, y calcula el CP de las ubicaciones publicadas. Gold consume Silver, no vuelve a resolver las claves desde RAW.

## Inventario

| Modelo | Materialización | Clave lógica | Grano |
| --- | --- | --- | --- |
| `arrest` | incremental | `arrest_number` | Última versión de una detención. |
| `arrest_offenses` | table | `arrest_offense_id` | Una combinación observada de detención, tipo y descripción NIBRS. |
| `arrest_types` | table | `arrest_type_id` | Un tipo de actuación de staging. |
| `cad_profiles` | table | `cad_profile_id` | Una combinación observada de cierre, tipo inicial y prioridad CAD. |
| `crimes` | incremental | `crime_id` | Última versión de un delito dentro de un informe. |
| `crime_shooting_types` | table | `(crime_id, shooting_type_id)` | Una etiqueta de tiroteo observada para un delito. |
| `nibrs` | table | `nibrs_key` | Última clasificación observada por código NIBRS. |
| `offense_categories` | table | `offense_category_id` | Una categoría de delitos de origen. |
| `offense_subcategories` | table | `offense_subcategory_id` | Una subcategoría en el contexto de la categoría informada (o sin padre). |
| `shooting_types` | table | `shooting_type_id` | Una etiqueta de tiroteo informada. |
| `full_address` | table | `address_id` | Una ubicación publicada con su contexto de calidad y resultado postal. |
| `police_add` | table | `police_area_id` | Una combinación de distrito, sector y beat, incluso parcial. |
| `postal_codes` | table | `cp` | Un CP de la cartografía activa o de licencias; como máximo una geometría. |
| `agents` | table | `agent_key` | Último perfil observado por `officer_id`. |
| `subject` | table | `subject_key` | Último perfil observado por `sk_person`. |
| `reports` | table | `report_id` | Un número de informe, con fecha de reporte solo de delitos. |
| `licenses` | incremental | `license_number` | Última versión de una licencia, no de un animal. |

Las claves son lógicas y se validan con pruebas dbt. Los catálogos de etiquetas usan el valor normalizado; las claves de combinaciones usan `MD5(TO_JSON(ARRAY_CONSTRUCT(...)))`, con un orden fijo para distinguir los campos y sus nulos sin ambigüedad de separadores.

## Informes, delitos y clasificaciones

**`reports` es la referencia común, no un puente delito–detención.** En arrestos, staging solo transforma `YYYY0000NNNNNN` en `YYYY-NNNNNN`; conserva los ceros y los demás formatos para revisión. `reports` reúne los números no nulos de ambos orígenes y usa `report_id = md5(report_number)`. La fecha y hora se toma de la última observación del informe en delitos. Si solo hay detenciones, no se imputa con la fecha del arresto. Unir ambos hechos por informe puede producir todas las combinaciones de sus delitos y detenciones, no una correspondencia individual.

**El grano de `crimes` es `(report_id, offense_id)`.** `crime_id = md5(report_id || '|' || offense_id)`; el hash del informe tiene longitud fija. Se usa la pareja, no solo `offense_id`: el [análisis de RAW](informe_grano_seattle.md) encontró el identificador `71157844528` en dos informes. El test emite un aviso; sin señal de baja no se elimina ninguna pareja. La fecha del delito sigue en `crimes`; la del informe se consulta en `reports`.

**Las etiquetas de tiroteo no forman parte del grano del delito.** En una captura de referencia de 1.575.312 filas había 1.575.310 parejas; las dos parejas repetidas diferían solo en la etiqueta de tiroteo. El puente recupera las etiquetas no nulas de staging, las deduplica por pareja delito–tipo y las vincula a los delitos publicados. Staging convierte `-` en nulo, no en una categoría más.

**La jerarquía de Seattle y NIBRS son independientes.** La muestra tenía 3 categorías y 31 subcategorías. Aunque cada etiqueta tenía un solo padre en esa muestra, se incluye la categoría en la clave de subcategoría para no mezclar etiquetas futuras. El hecho conserva las dos referencias: una categoría puede existir sin subcategoría; una subcategoría sin categoría no recibe un padre inventado. La muestra tenía 64 códigos NIBRS y 1.643 filas con categoría pero sin código. `nibrs` se resuelve por código y elige una fila completa por código (descripción, grupo A/B y categoría `crime_against_category`), no una fila por variante ni una clasificación deducida de la jerarquía de Seattle.

## Detenciones, personas y cargos

- **Una fila por `arrest_number`, no por informe ni por cargo.** En la captura revisada, 145.625 filas representaban 110.143 detenciones y una alcanzaba 11 cargos. Se conserva la última fila completa de la detención, con sus dos fechas, referencias, edades `officer_age` y `subject_age_range` e indicadores booleanos (un nulo no se convierte en `false`). Los atributos de área, ubicación y CAD se consultan en sus respectivos modelos, no se duplican en el hecho.
- **Identidad estable; atributos más recientes, sin vigencias.** Las claves `agent_key` y `subject_key` son hashes del `officer_id` y del `subject_id` de staging (`sk_person` en Silver). No cambian si cambian los atributos. Si la versión de una detención no informa un ID, la referencia queda nula; no se crea una persona ficticia. Las edades se guardan en el evento, no en el perfil.
- **Un cargo observado por `(arrest_number, offense_type, nibrs_description)`.** Se lee toda la evidencia de staging para las detenciones publicadas, incluida la que no está en su última fila. Las 71 filas de la muestra sin tipo ni descripción no generan un cargo. `offense_type` es texto sin atributos propios: no se añade `offense_types`. Se observaron 521 textos legales vinculados a más de una descripción NIBRS. Se conserva la descripción publicada, pero no se infiere un código ni existe una FK de `arrest_offenses` a `nibrs`.
- **CAD es un perfil, no una llamada.** `cad_profiles` se construye desde staging con `(cad_clearance, cad_initial_call_type, cad_priority)`. Admite combinaciones parciales; si faltan los tres campos, el arresto no tiene referencia. `arrest_types` recoge el tipo normalizado de actuación; no todas las modalidades implican custodia física.

Ambos puentes representan **asociaciones observadas en los datos conservados**, no necesariamente vigentes. Un diferencial puede aportar un cargo o etiqueta sin repetir los anteriores; no tiene identificador de cargo, bajas ni garantía de que incluya todo el conjunto de asociaciones. Una omisión no se interpreta como retirada. Para contar eventos, agregar o filtrar mediante el puente sin multiplicar el hecho, o contar claves de evento distintas.

## Áreas, cartografía y código postal

- **Área policial:** `police_add` une las combinaciones `(precinct, sector, beat)` de ambos dominios. Un beat no se presupone único; se conservan las áreas parciales y se omite la combinación completamente nula.
- **Identidad de la ubicación:** `full_address` usa bloque, coordenadas, barrio, área de reporte, bloque censal e indicadores de calidad. Staging evalúa los marcadores, la conversión y los rangos globales antes de publicar las coordenadas a cinco decimales (`NUMBER(18,5)`). Cuando la ubicación está ocultada o sus coordenadas faltan o son inválidas, `location_context` incorpora el origen y la clave del evento (`A:` o `C:`), si están disponibles; así no se confunden ausencias con ubicaciones compartidas. `address_id` no depende del CP, de `cp_status` ni de la versión del mapa. No se recupera el punto de una versión anterior para sustituir una ubicación ocultada.
- **Una versión cartográfica activa:** la capa de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) usa EPSG:2926 en origen y se exportó a EPSG:4326. La descarga de referencia (`kingcounty_download_2026-11-19`) tenía 273 entidades y 251 CP distintos. Un pre-hook comprueba que la versión seleccionada tenga el recuento esperado, IDs no nulos y únicos, CP de cinco dígitos y polígonos válidos. `postal_codes` disuelve sus piezas con `ST_UNION_AGG` y publica una geometría por CP. Incorpora también CP válidos de staging de licencias: si no hay polígono local, conserva `geography` y `boundary_version` nulos.
- **Asignación conservadora:** `full_address` interpreta las coordenadas policiales como EPSG:4326 por convención del proyecto, sin variable de confirmación. Forma el punto con `ST_MAKEPOINT(longitude, latitude)`, cuenta los CP que lo cubren (`ST_COVERS`) y comprueba que esté en el interior (`ST_CONTAINS`). No aproxima al CP más cercano ni elige arbitrariamente cuando hay solape. Guarda el CP y su estado juntos; no hay tabla adicional de asignaciones, recuento persistido de candidatos ni histórico de evaluaciones. `boundary_version` identifica la descarga del polígono activo, no una vigencia histórica.

| `cp_status` (orden de evaluación) | Motivo | `cp` |
| --- | --- | --- |
| `redacted` | El origen marca la ubicación como ocultada. | Nulo |
| `missing_coordinates` | Falta alguna coordenada. | Nulo |
| `invalid_coordinates` | Coordenadas no convertibles o fuera de los rangos válidos, sin aplicar los estados anteriores. | Nulo |
| `no_match` | Ninguna zona cubre el punto. | Nulo |
| `ambiguous` | Más de un CP cubre el punto. | Nulo |
| `boundary` | Solo una zona cubre el punto, pero está en el límite. | Nulo |
| `matched` | Solo una zona cubre el punto y este cae en su interior. | CP encontrado |

Los hechos policiales consultan el CP a través de `address_id`. Un punto puede ser aproximado o quedar fuera del mapa; no se obtiene una dirección exacta ni se valida contra USPS. La cobertura postal no equivale a los límites municipales de Seattle.

## Licencias de mascotas

`licenses` conserva una fila por `license_number`. En las 38.413 filas revisadas había 38.410 números y las tres repeticiones eran duplicados exactos de negocio. Se eligió reemplazar por número en vez de conservar variantes con `DISTINCT`: `license_id = md5(license_number || '|' || coalesce(animal_name, ''))` es un identificador alternativo que cambia al cambiar el nombre del animal. Staging prueba que el número no contiene el separador. No se deducen mascotas únicas, renovaciones ni licencias vigentes.

El CP proviene directamente del ZIP de origen si tiene cinco dígitos; permanece como texto para no perder ceros. Un valor ausente o mal formado queda nulo sin descartar la licencia ni rellenar el código por suposición. La unión con delitos y detenciones es geográfica por CP, nunca entre personas, mascotas y hechos. Agregar cada dominio por CP (y por periodo, si corresponde) antes de compararlos. Véase [Gold](gold.md) para las dimensiones y los hechos que exponen estos datos.

## Carga y selección de versiones

Solo `arrest`, `crimes` y `licenses` usan `delete+insert`, con `on_schema_change='fail'`, sus claves del inventario y `ROW_NUMBER()` para obtener una única versión elegible. Los otros 14 modelos se reconstruyen como tablas: no tienen un cursor propio ni usan la detección anterior por diferencias de catálogo. Se retiró la consolidación por campo con `MERGE` y la tabla de conflictos: una versión más reciente reemplaza **la fila completa, incluidos los nulos**, sin combinar observaciones distintas.

1. En una ejecución incremental, [`after_max_ingested_at`](../macros/utils/after_max_ingested_at.sql) filtra por `ingested_at > MAX(ingested_at)` de la tabla destino de ese modelo. El corte es **global por modelo**, no por clave. No se usa la fecha del evento ni el lote como cursor. Las claves requeridas y la fecha de ingesta del candidato deben estar informadas.
2. Dentro de las filas elegibles, gana la mayor fecha de ingesta por clave. Para empates, delitos y detenciones ordenan por fichero, lote, fechas del hecho y contenido; licencias prioriza fecha de expedición y después fichero, lote y atributos. Es un desempate estable, no evidencia de qué versión se editó primero. Fichero y lote quedan en staging; los tres incrementales publican `ingested_at`.
3. Si un lote llega con fecha **igual o inferior** al máximo, se omite incluso una clave nueva. La primera construcción y `--full-refresh` no tienen el corte. Una tabla existente vacía devuelve `MAX = NULL`; debe reconstruirse con `--full-refresh` para volver a poblarla. Las pruebas de cobertura detectan claves faltantes y versiones desactualizadas, pero no prueban qué fila ganó dentro de un mismo `ingested_at`.
4. Silver no propaga bajas desde RAW en sus incrementales. Conservar todo el histórico de ingesta necesario para rehacer tablas y puentes; un `--full-refresh` no recupera filas que ya no estén en RAW. No ejecutar cargas simultáneas contra el mismo destino.

## Ejecución en DEV

En dbt Core, configurar el perfil `default` fuera del repositorio; en Studio, usar las variables del entorno de desarrollo. El rol necesita warehouse, lectura de RAW y escritura en STG y SILVER. `DBT_BRONZE` y `DBT_SILVER` son obligatorias y `--target` no cambia sus valores; la macro de esquemas respeta los nombres configurados sin prefijo. [`packages.yml`](../packages.yml) fija `dbt_utils` 1.4.1.

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER
dbt deps
dbt parse --target dev
# Verificar las bases y el mapa activo antes de crear o reemplazar tablas:
dbt build --target dev --select '+path:models/silver'
```

Confirmar que `RAW.ZIPCODE_AREAS` contiene la versión esperada. Para seleccionar otra descarga, definir **juntas** `zipcode_boundary_version` y `zipcode_expected_feature_count`. Reconstruir `postal_codes` y `full_address` en la misma ejecución; un cambio solo de mapa no modifica `address_id` ni requiere por sí mismo reescribir los hechos.

Si ya existe un Silver anterior, comparar columnas, granos y claves, verificar el histórico de RAW, respaldar los destinos y coordinar la reconstrucción con los consumidores de Gold. `on_schema_change='fail'` no migra columnas ni claves; renombrar `licencia` a `licenses` tampoco borra la relación antigua. No usar `--full-refresh` sobre el entorno compartido sin plan de migración y autorización.

## Pruebas y estado de validación

- [`_silver_models.yml`](../models/silver/_silver_models.yml) declara unicidad, no nulidad, relaciones, el formato de informe, el grano compuesto y la coherencia `cp_status = 'matched'` si y solo si hay CP. Las [pruebas singulares](../tests/singular/) comprueban cobertura y última ingesta por clave, preservación de cargos y etiquetas, coherencia categoría–subcategoría, precisión de coordenadas y el aviso por `offense_id` en varios informes. La validez de los polígonos de la versión activa se comprueba además antes de construir `postal_codes`.
- La [regresión sintética de Snowflake](../tests/integration/arrest_delete_insert_check.py) crea y elimina su propio esquema DEV. Ejercita la carga inicial, CP con cero inicial, reemplazo con nulos y ocultación, asociaciones observadas, empates, altas anteriores o iguales al corte, repetición sin novedades y recuperación mediante `--full-refresh`. Usa dbt-snowflake, PyYAML, el conector y una conexión JWT externa (`SNOWFLAKE_CONNECTION_NAME`, por defecto `civica`; `DBT_BIN` permite elegir el ejecutable).
- Los recuentos citados son observaciones de capturas de referencia, no contratos ni recuentos de un despliegue actual. Se documentaron consultas de solo lectura, pruebas locales con datos de ejemplo y una [validación histórica del `MERGE`](arrest_incremental.md#validación-de-la-implementación-inicial-del-merge). **No consta un `dbt build` integral de esta versión con datos reales en Snowflake DEV**; ejecutarlo y revisar cobertura, estados postales y comportamiento del segundo pase sigue siendo el paso de validación antes de publicar.
