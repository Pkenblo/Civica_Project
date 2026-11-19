# Arrest: consolidación incremental con MERGE

## Alcance y retirada de la implementación anterior

Se conserva el trabajo previo de staging/Silver y las reorganizaciones locales de carpetas.
Se retiran la estrategia y los parámetros microbatch de `arrest`, el flag global de ejecución
por lotes, `event_time` de staging, la escritura global personalizada, el catálogo de estados
por intervalo y el test de tokens de microbatch. Se conserva `on_schema_change='fail'`.
No se restauran archivos mediante Git ni se alteran las tablas existentes de Snowflake.

Las macros de negocio viven en `macros/arrests/`; `macros/utils/` no se modifica.
No se recrea el modelo intermedio eliminado por el usuario.

## Grano y fuente de actualización

- `arrest`: una fila por `arrest_number` (`unique_key`).
- `arrest_offenses`: una asociación por detención, tipo y descripción NIBRS. Se conservan
  todas las asociaciones observadas, no solo las del último fichero.
- En DEV RAW hay 147.187 filas y 110.143 números de detención. `20-005825` tiene once
  infracciones distintas en un mismo fichero: son detalles legítimos, no once detenciones.
- `_INGESTED_AT` es `TIMESTAMP_LTZ`, está informado en todas las filas y tiene
  `CURRENT_TIMESTAMP()` por defecto. La task `TASK_LOAD_ARRESTS` carga explícitamente
  `METADATA$START_SCAN_TIME`. No hace falta cambiar ni reconstruir la ingesta inicial/batch.
- `_SOURCE_UPDATED_AT` está a NULL en todas las filas: no se usa.
- `batch_id` no se usa como cursor. El lote `1001` contiene dos ficheros y dos instantes de
  ingesta distintos. No se interpreta como una secuencia temporal de versiones.

## Detección incremental

Se inventarían las versiones distintas de los atributos normalizados con su fecha real de
ingesta en UTC. El destino guarda `last_ingested_at`, `source_version_count` y `source_signature`.
La firma ordenada es independiente del orden de lectura y de las filas repetidas por infracciones.

`is_incremental()` compara este inventario por detención con `{{ this }}`. Solo para IDs nuevos o
cambiados se recupera el histórico completo de staging y se ejecuta la consolidación.
No se usa un máximo global ni la fecha del hecho. También se detecta una versión nueva con el mismo
timestamp, o una ingesta antigua añadida tardíamente, si cambian sus atributos normalizados.
Sin novedades, el origen de MERGE queda vacío. La lectura de metadatos/inventario sigue siendo
necesaria; esto no significa que dbt no ejecute consultas.

RAW debe mantenerse append-only: las versiones anteriores son la evidencia que permite recalcular
el ganador. No se borran versiones para ahorrar lecturas. La información de destinos existentes se
protege además completando atributos desde `consolidation_choices` del destino antes de recalcular
sus claves, y con `COALESCE` explícito por columna nullable en la proyección que recibe MERGE.

## Consolidación y conflictos

Cada atributo conserva el primer valor **no nulo** ordenado por:

1. Mayor completitud de la versión: número de los 31 campos informativos no nulos.
2. Fecha real de ingesta más reciente.
3. SHA-256 descendente de los atributos normalizados (desempate estable).

No suman la PK, el lote, el fichero, las fechas de control, hashes, flags derivados ni los campos
de infracción. `false` y `0` sí son datos informativos. La completitud se calcula sobre versiones
originales, no sobre una fila consolidada artificialmente más completa.
Los nulos se saltan individualmente: un registro menos completo todavía puede aportar un atributo
que no estuviera informado en el registro ganador. No se selecciona una única fila completa.

`consolidation_conflicts` expone los valores candidatos distintos; `consolidation_choices` expone
la combinación seleccionada antes de generar las claves. La vista `arrest_conflicts` muestra un
registro por detención y campo contradictorio, sus candidatos y el valor seleccionado.

Se mantienen dos protecciones semánticas preexistentes: no se atribuyen datos de un agente/sujeto
a otro identificador, y una marca de ocultación impide recuperar ubicaciones anteriores. Los
atributos censurados no se exponen en el detalle de conflictos. No son pérdidas accidentales por
NULL: la evidencia original permanece en RAW y los catálogos conservan observaciones legítimas.

## Decimales y entornos

Staging convierte numéricamente y publica latitud/longitud como `NUMBER(18,5)` usando `ROUND(...,5)`.
La normalización precede a completitud, firmas, comparación, claves y almacenamiento en Silver.
`officer_age` y `cad_priority` son enteros; se verificó que RAW no tiene valores fraccionarios en
ellos. No se redondean identificadores, fechas ni geometrías cartográficas.

Se mantienen `DBT_BRONZE`, `DBT_SILVER`, los esquemas RAW/STG/SILVER y las macros de esquema
existentes. PRE/PRO deben proporcionar sus variables y permisos propios; no se escriben allí.

## Despliegue y seguridad

En DEV no existe una tabla `DEV_SILVER.SILVER.ARREST` al revisar esta implementación.
No se ejecuta `--full-refresh` sobre las tablas del proyecto. Si otra instalación ya tiene el
esquema experimental anterior, `on_schema_change='fail'` bloqueará su cambio: conservar primero
una copia y realizar una migración aditiva revisada, o construir una tabla paralela y validar
antes de cambiar el destino. No se elimina información automáticamente para adaptar el esquema.

El cruce espacial real de `full_address` conserva su bloqueo pendiente de confirmar el CRS.
Las pruebas con escrituras se realizan en un esquema de pruebas aislado, nunca en Silver real.

## Pruebas reproducibles

La regresión está en `tests/integration/arrest_merge_check.py`. Usa la conexión Snowflake local
`civica` por defecto (configurable con `SNOWFLAKE_CONNECTION_NAME`), crea un esquema con UUID,
ejecuta `dbt parse`, `dbt compile`, varias cargas `dbt run` y `dbt test`, y elimina únicamente
ese esquema propio. No ejecuta `--full-refresh`. El Python empleado necesita dbt-snowflake,
PyYAML y el conector de Snowflake, con autenticación JWT ya configurada fuera del repositorio.

```bash
DBT_BIN=/ruta/al/dbt python tests/integration/arrest_merge_check.py
```

Incluye altas, atributos complementarios, nulos, varias versiones por lote, decimales equivalentes,
actualización de un arresto de 2011, repetición sin novedades (cero filas afectadas en MERGE),
conflictos por completitud/fecha/hash y conservación de dos infracciones legítimas. También prueba
que un valor del destino no presente en el origen no se borra al recibir NULL, incluidos `false` y `0`.

Los tests de esquema están en `models/silver/arrests/_arrest_models.yml`; las invariantes SQL
están en `tests/singular/` y la regresión de la macro con fixtures en `tests/unit/`.
Los datasets ajenos a Arrest se sustituyen en el sandbox por vistas sintéticas vacías. No debe
interpretarse esta regresión como validación del CRS policial real ni de las cargas PRE/PRO.

## Resultado de la validación

Con dbt Core 1.10.23 y dbt-snowflake 1.10.8:

- `dbt parse` y `dbt compile` sobre una copia completa del proyecto: correctos.
- Regresión nativa aislada con staging real, carga inicial, MERGE con novedades y repetición:
  los nueve casos obligatorios pasan; la repetición afecta cero filas del modelo `arrest`.
- `dbt test` del conjunto aislado afectado: **57 pasan** (50 data tests y 7 unit tests).
- Consultas sobre los datos reales, materializadas solo en tablas temporales: 110.143 filas
  para 110.143 detenciones, 145.565 asociaciones de infracciones conservadas, cero referencias
  rotas y 652 detenciones con conflictos expuestos. No hay atributos base contradictorios
  dentro de un mismo fichero para un arrest_number en los datos revisados.

No se ha desplegado ni reemplazado Silver real. El entorno aislado de prueba se eliminó al terminar.
Se mantienen los avisos preexistentes del runtime de dbt y de la ruta de ejemplo sin modelos;
no se modificaron dependencias del proyecto ni la configuración del usuario para ocultarlos.

## Archivos afectados

- `dbt_project.yml`: retirada del flag microbatch.
- `models/staging/stg_arrests.sql`: retirada de event_time; se conserva el redondeo previo.
- `models/staging/_stg_models.yml`: tipos de coordenadas alineados con NUMBER(18,5).
- `models/silver/arrests/arrest.sql`: MERGE e incrementalidad por ingesta/inventario.
- `models/silver/arrests/arrest_conflicts.sql` y `_arrest_models.yml`: auditoría y contratos/tests.
- `models/silver/arrests/agents.sql`, `subject.sql`, y
  `models/silver/geography/police_add.sql`, `full_address.sql`: consolidación de negocio compartida,
  sin estados por intervalos microbatch.
- `macros/arrests/arrest_business_columns.sql`, `arrest_scored_versions.sql`, `consolidate_arrests.sql`:
  campos informativos, completitud/desempate y consolidación por atributo.
- Retirada de `macros/arrest_microbatch/get_incremental_microbatch_sql.sql` y
  `arrest_catalog_observations.sql`; la macro de consolidación se traslada a `macros/arrests/`.
- `tests/unit/arrest_consolidation_preserves_values.sql`: expectativas según la nueva prioridad.
- `tests/singular/arrest_consolidation_unique.sql`, `arrest_ingestion_metadata.sql`,
  `arrest_coordinates_five_decimals.sql`, `arrest_offenses_preserved.sql`,
  `arrest_source_versions_complete.sql`; se retira `arrest_microbatch_tracking.sql`.
- `tests/integration/arrest_merge_check.py`: regresión reproducible con el runner real.
- Este documento. No se modifican los scripts de ingesta, systemd, los diagramas ni las utilidades
  movidas previamente por el usuario a `macros/utils/`.
