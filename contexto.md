# Civica Project — contexto para retomar

**Nota de versión:** las decisiones de Silver y el procedimiento de ejecución de este contexto corresponden al diseño anterior. Para el código actual, consultar [Silver de Seattle](docs/silver.md).

Proyecto dbt sobre Snowflake para delitos, detenciones, licencias de mascotas y cartografía postal de Seattle. La comparación por CP es **geográfica**, no una relación entre mascotas, personas y hechos policiales. El [README](README.md) es la memoria de decisiones; este archivo resume el estado, las reglas que no deben perderse y el orden para validar o continuar.

## Qué hay y qué se ha comprobado

- Repositorio: [Pkenblo/Civica_Project](https://github.com/Pkenblo/Civica_Project). Consultar `git status` y `git log` al retomar: puede haber trabajo local sin commit. No descartarlo ni hacer commits o pushes sin petición.
- **Bronze:** `CRIMES`, `ARRESTS`, `PET_LICENSES`, `ZIPCODE_AREAS`. dbt declara las fuentes; no carga RAW. **Staging:** `stg_crimes`, `stg_arrests`, `stg_pet_licenses`, `stg_zipcode_areas`, todos vistas. Las cuatro vistas existían en el entorno consultado anteriormente; no asumir que estén publicadas con el SQL actual.
- **Silver:** modelos en `models/silver/`, sin Gold ni snapshots en uso. El [diccionario y DBML](docs/silver_diagram.md) y el [SVG](docs/silver_diagram.svg) conservan el diseño anterior al cambio de detenciones; SQL y YAML prevalecen.
- **Validación:** no consta un `dbt build` integral satisfactorio de la versión actual en Snowflake. La [regresión de la primera versión de `MERGE`](docs/arrest_incremental.md#validación-de-la-implementación-inicial-del-merge) se hizo en un esquema aislado y no valida el reemplazo actual.

## Contratos que hay que conservar

### Staging y fuentes

Normalizar tipos, espacios, vacíos y marcadores en staging. Los textos descriptivos y los códigos se publican en mayúsculas; `arrest_type` también unifica espacios internos. No alterar la escritura de IDs de origen, `source_file`, `batch_id` ni `boundary_version`: en los datos revisados había números de licencia alfanuméricos con minúsculas. Staging conserva todas las filas y asociaciones. Las coordenadas se publican con cinco decimales (`NUMBER(18,5)`) y se evalúan marcadores y rangos antes de redondear. Mantener la distinción entre valores ausentes, inválidos y ocultados. Los fixtures unitarios de Silver deben representar entradas ya normalizadas; dbt no ejecuta upstream dentro de esas pruebas.

### Delitos e informes

- `crimes` descarta duplicados completos, pero admite variantes de un mismo `offense_id`. No declararlo único sin decidir cómo consolidar versiones. `crime_shooting_types` extrae los tipos antes de deduplicar el hecho. `reports` recoge números de ambos orígenes; staging de arrestos convierte únicamente `YYYY0000NNNNNN` a `YYYY-NNNNNN`. La fecha del informe procede solo de delitos. Un informe compartido no identifica un vínculo particular delito–detención.
- `crimes` guarda `offense_category_id` y `offense_subcategory_id`. `offense_subcategories` distingue la etiqueta dentro de su categoría; si solo se informa la etiqueta, el padre queda nulo. Mantener ambos IDs en el hecho permite conservar una categoría sin subcategoría. `nibrs` es otra clasificación y no debe ser el camino obligatorio para obtener la categoría. En el CSV local: 3 categorías, 31 subcategorías, 64 códigos NIBRS informados y 1.643 filas con categoría pero sin código.

### Detenciones

- `arrest` usa `delete+insert` por `arrest_number`. Elige una fila completa por fecha de ingesta. Los nulos reemplazan los valores anteriores y una ubicación `REDACTED` no recupera atributos de otras versiones. No se usa un cursor global de ingesta ni se propagan bajas de RAW.
- `agents` y `subject` mantienen una fila por `officer_id` y `sk_person`, respectivamente. Las claves de relación se derivan solo de esos IDs; un ID ausente en la detención deja la referencia nula. Las edades siguen en `arrest`: `agents_age_at_detention` y `subgect_age_at_detention`.
- `arrest_offenses` conserva los cargos por tipo y descripción NIBRS observados. `cad_profiles` se construye después de `arrest` y `cad_profile_id` es nulo si faltan los tres atributos CAD. Véase [Detenciones en Silver](docs/arrests.md).

### Incrementales de catálogos

Los modelos de detenciones y sus catálogos usan `delete+insert`, cada uno con su propia `unique_key`. La [macro](macros/utils/changed_catalog_rows.sql) usa `is_incremental()` y `MINUS` de candidatos menos destino para detectar claves con alguna fila nueva o distinta; entrega todas las filas de origen de esas claves para reemplazarlas juntas. Así no pierde variantes NIBRS de una clave reemplazada. No detecta por sí sola bajas del origen. Los unit tests de estos modelos declaran `overrides.macros.is_incremental`; los de rama incremental incluyen un fixture `this`.

### Geografía y licencias

- `police_add` usa `(precinct, sector, beat)` y conserva áreas parciales. `address_id` comparte el mismo contrato en hechos y `full_address`; no depende del CP ni de la versión postal. No cambiarlo en un solo modelo. `full_address` tiene el bloqueo `police_coordinates_epsg4326_confirmed` y solo publica CP ante una coincidencia interior única. No quitar el bloqueo ni darlo por superado a partir de datos sintéticos.
- `postal_codes` une las piezas de una única versión y valida cantidad, IDs, CP y geometrías. La versión por defecto es `kingcounty_download_2026-11-19` y el recuento esperado son 273 entidades; para otro mapa, configurar `zipcode_boundary_version` y `zipcode_expected_feature_count` conjuntamente. El GeoJSON de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) se exportó a EPSG:4326 y el usuario confirmó su carga en `DEV_BRONZE.RAW.ZIPCODE_AREAS`; no repetirla por defecto. La capa nativa usa EPSG:2926.
- `licencia` usa el ZIP de origen si tiene cinco dígitos; no imputar uno por cercanía ni añadir ceros a valores inválidos. `license_id` es el hash de `license_number` y `animal_name`, exclusivamente. La unicidad por `license_number` señala variantes; no elegir una a ciegas ni afirmar que se guardan vigencias. Un CP válido de licencias puede estar en `postal_codes` sin geometría.

## Entorno y procedimientos

El nombre técnico es `my_new_project`, el perfil local `default` y `dbt_utils` está fijado en 1.4.1. `DBT_BRONZE=DEV_BRONZE` y `DBT_SILVER=DEV_SILVER` son explícitos en DEV y se necesitan incluso para parsear una selección parcial. `--target` no las cambia. `RAW` y `STG` están en Bronze; `SILVER`, en Silver. `generate_schema_name` respeta los esquemas configurados, no los aísla con el nombre del target. Si se prueba en una base aislada, comprobar también el destino de staging para no reemplazar las vistas DEV ni escribir en RAW. PRE y PRO requieren bases y permisos propios.

Las comprobaciones locales recientes usaron dbt Core 1.12.7 y dbt-snowflake 1.12.5. No asumir que el otro equipo tenga las mismas versiones o que necesite instalarlas si se usa Studio. Para Core, configurar `~/.dbt/profiles.yml` fuera del repositorio. No copiar credenciales a Git, Markdown ni chat. El [runner de integración](tests/integration/arrest_delete_insert_check.py) necesita el conector, PyYAML, dbt-snowflake y una conexión Snowflake con JWT configurada externamente (`SNOWFLAKE_CONNECTION_NAME`, por defecto `civica`; `DBT_BIN` permite indicar el ejecutable). Crea y elimina su propio esquema de prueba con datos sintéticos; no ejecuta `--full-refresh` ni prueba el CRS real.

### Ingesta y datos locales

- `Datos_ejemplo/` está ignorada y no llega con el clon. Los modelos leen Snowflake, nunca esos CSV. No subir la carpeta a Git.
- `scripts/`, `systemd/` y `requirements.txt` pertenecen a la ingesta externa documentada en sesiones anteriores y no están en este checkout. `batch_crimes.py` y `batch_arrests.py` usaban `batch_common.py` para descargar cambios de Seattle Open Data, comparar hashes y multiplicidades en SQLite y subir gzip a `DEV_BRONZE.RAW.STG_SEATTLE_BATCH/`. No reflejan bajas ni automatizan licencias o cartografía. No asumir que la automatización se restaura al clonar.
- Si se trabaja con esa copia, preservar `scripts/state/` y los pendientes. `--inicial` y `--inicial-web` registran el estado base, no suben RAW; no reinicializar entre cargas ni asumir que la base web coincide con lo ya cargado. `run_daily.sh` preparaba ambos conjuntos en paralelo con su entorno del conector, no con dbt. La programación documentada era a las 03:00 locales para los scripts, con reintentos, y una task esperada a las 04:00; no se ha comprobado que ambas estén activas ni la zona horaria efectiva de la task.

## Por dónde retomar

1. **Resolver el choque de `officer_id`.** El test `not_null` de `stg_arrests.officer_id` rechaza un caso que Silver admite y que el runner incluye deliberadamente. Acordar si el dato ausente en staging se permite o se notifica sin bloquear el build.
2. **Confirmar el CRS policial y validar en Snowflake DEV aislado.** Empezar por `dbt deps` y `dbt parse`; ejecutar integración de arrestos y el `dbt build` de staging/Silver en un destino verificado. Los catálogos que dependen del hecho, como `cad_profiles`, deben quedar en la selección si se quieren actualizar. Verificar también las referencias de categorías, los perfiles CAD, los estados de CP y los `delete+insert` con una segunda ejecución sin novedades.
3. **Si ya existe un esquema Silver antiguo, preparar la migración antes de escribir.** Revisar columnas y claves de `arrest`, `agents` y `subject`, y coordinar la reconstrucción con `cad_profiles` y los consumidores. Mantener `on_schema_change='fail'`. No lanzar `--full-refresh` ni operaciones destructivas sin autorización, verificación de RAW y respaldo de destinos. Si no existe la tabla, basta la primera carga normal.
4. **Dejar abiertas las decisiones que no se han tomado:** grano definitivo de `crimes`, posibles snapshots o vigencias y diseño Gold. No presentar propuestas como implementaciones ni resultados de DuckDB como pruebas nativas de Snowflake.

Preferencias del proyecto: revisar datos y SQL antes de cambiar el diseño, mantener las soluciones incrementales simples y no reintroducir los 42 usos de `normalized_text` que se retiraron. Modificar otros Markdown o el diagrama solo si se pide; cuando se actualice el diagrama, conservar el DBML completo y el estilo visual del SVG.
