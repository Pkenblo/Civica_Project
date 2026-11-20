# Civica Project — contexto para retomar

Proyecto dbt sobre Snowflake para delitos, detenciones, licencias de mascotas y cartografía postal de Seattle. La comparación por CP es **geográfica**, no una relación entre mascotas, personas y hechos policiales. El [README](README.md) es la memoria de decisiones; este archivo resume el estado, las reglas que no deben perderse y el orden para validar o continuar.

## Qué hay y qué se ha comprobado

- Repositorio: [Pkenblo/Civica_Project](https://github.com/Pkenblo/Civica_Project). Consultar `git status` y `git log` al retomar: puede haber trabajo local sin commit. No descartarlo ni hacer commits o pushes sin petición.
- **Bronze:** `CRIMES`, `ARRESTS`, `PET_LICENSES`, `ZIPCODE_AREAS`. dbt declara las fuentes; no carga RAW. **Staging:** `stg_crimes`, `stg_arrests`, `stg_pet_licenses`, `stg_zipcode_areas`, todos vistas. Las cuatro vistas existían en el entorno consultado anteriormente; no asumir que estén publicadas con el SQL actual.
- **Silver:** 19 modelos en `models/silver/`: 11 incrementales, 7 tablas completas y la vista `arrest_conflicts`. Sin Gold ni snapshots en uso. [Diccionario y DBML](docs/silver_diagram.md) y [SVG](docs/silver_diagram.svg): 19 modelos, 100 columnas y 21 relaciones lógicas. SQL y YAML prevalecen si alguna nota histórica difiere. `docs/fallos.md` y `docs/codigo_postal.md` conservan revisiones antiguas.
- **Validación actual:** `dbt parse`, compilaciones locales de los modelos afectados y comprobaciones sintéticas en DuckDB. Último manifiesto: 98 pruebas de datos y 24 unitarias declaradas. **No consta un `dbt build` integral satisfactorio de esta versión en Snowflake.** La [regresión nativa de la primera versión de `MERGE`](docs/arrest_incremental.md#validación-de-la-implementación-inicial-del-merge) se hizo en un esquema aislado y no valida los cambios posteriores.

## Contratos que hay que conservar

### Staging y fuentes

Normalizar tipos, espacios, vacíos y marcadores en staging. Los textos descriptivos y los códigos se publican en mayúsculas; `arrest_type` también unifica espacios internos. No alterar la escritura de IDs de origen, `source_file`, `batch_id` ni `boundary_version`: en los datos revisados había números de licencia alfanuméricos con minúsculas. Staging conserva todas las filas y asociaciones. Las coordenadas se publican con cinco decimales (`NUMBER(18,5)`) y se evalúan marcadores y rangos antes de redondear. Mantener la distinción entre valores ausentes, inválidos y ocultados. Los fixtures unitarios de Silver deben representar entradas ya normalizadas; dbt no ejecuta upstream dentro de esas pruebas.

### Delitos e informes

- `crimes` descarta duplicados completos, pero admite variantes de un mismo `offense_id`. No declararlo único sin decidir cómo consolidar versiones. `crime_shooting_types` extrae los tipos antes de deduplicar el hecho. `reports` recoge números de ambos orígenes; staging de arrestos convierte únicamente `YYYY0000NNNNNN` a `YYYY-NNNNNN`. La fecha del informe procede solo de delitos. Un informe compartido no identifica un vínculo particular delito–detención.
- `crimes` guarda `offense_category_id` y `offense_subcategory_id`. `offense_subcategories` distingue la etiqueta dentro de su categoría; si solo se informa la etiqueta, el padre queda nulo. Mantener ambos IDs en el hecho permite conservar una categoría sin subcategoría. `nibrs` es otra clasificación y no debe ser el camino obligatorio para obtener la categoría. En el CSV local: 3 categorías, 31 subcategorías, 64 códigos NIBRS informados y 1.643 filas con categoría pero sin código.

### Detenciones

- `arrest` es un `MERGE` por `arrest_number`, sin hash para esa clave. Detecta IDs afectados con fecha real de ingesta, recuento de versiones y firma del contenido normalizado. No usar la fecha del arresto, un máximo global de ingesta ni `batch_id` como cursor. No reintroducir microbatch ni una etiqueta de versión de la lógica en la firma. El cálculo de afectados escanea staging; después solo se consolida el historial de esos IDs. RAW es el histórico y debe conservarse.
- Por columna gana el valor no nulo más reciente por `ingested_at`, con hash para empates. La completitud es una métrica. `NULL`, incluidos los atributos de ubicación de versiones `REDACTED`, no borra valores válidos. Si la última versión está marcada y no hay ubicación disponible, se conserva `redacted`. No deducir localizaciones ocultadas.
- El último agente o sujeto identificado determina qué atributos pueden combinarse; nunca pasar atributos de `A1` a `A2`. Si el dato no existe para la identidad elegida, queda nulo. Mantener `subject_key = NULL` si no hay ID válido, sin sujeto ficticio. Las edades están en `arrest`: `agents_age_at_detention` y `subgect_age_at_detention` (usar la grafía exacta al consultar). No añadirlas a las claves de `agents` o `subject`; sus catálogos no son snapshots.
- `arrest_offenses` conserva los cargos por tipo y descripción NIBRS observados. `cad_profiles` se construye después de `arrest` y reúne los tres atributos CAD consolidados; no representa llamadas individuales. `cad_profile_id` es nulo si faltan los tres. `arrest_conflicts` explica las discrepancias por campo. Véanse [arrests.md](docs/arrests.md) y [arrest_incremental.md](docs/arrest_incremental.md) para detalle y antecedentes.

### Incrementales de catálogos

`cad_profiles`, `police_add`, `agents`, `subject`, `arrest_types`, `offense_types`, `nibrs`, `offense_categories`, `offense_subcategories` y `shooting_types` usan **`delete+insert`**, no `append`, cada uno con su propia `unique_key`. La [macro](macros/utils/changed_catalog_rows.sql) usa `is_incremental()` y `MINUS` de candidatos menos destino para detectar claves con alguna fila nueva o distinta; entrega todas las filas de origen de esas claves para reemplazarlas juntas. Así no pierde variantes NIBRS de una clave reemplazada. No detecta por sí sola bajas del origen. No añadir cursores ni estrategias personalizadas porque una vista de staging siga leyendo RAW. Los unit tests de estos modelos declaran `overrides.macros.is_incremental`; los de rama incremental incluyen un fixture `this`.

### Geografía y licencias

- `police_add` usa `(precinct, sector, beat)` y conserva áreas parciales. `address_id` comparte el mismo contrato en hechos y `full_address`; no depende del CP ni de la versión postal. No cambiarlo en un solo modelo. `full_address` tiene el bloqueo `police_coordinates_epsg4326_confirmed` y solo publica CP ante una coincidencia interior única. No quitar el bloqueo ni darlo por superado a partir de datos sintéticos.
- `postal_codes` une las piezas de una única versión y valida cantidad, IDs, CP y geometrías. La versión por defecto es `kingcounty_download_2026-11-19` y el recuento esperado son 273 entidades; para otro mapa, configurar `zipcode_boundary_version` y `zipcode_expected_feature_count` conjuntamente. El GeoJSON de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) se exportó a EPSG:4326 y el usuario confirmó su carga en `DEV_BRONZE.RAW.ZIPCODE_AREAS`; no repetirla por defecto. La capa nativa usa EPSG:2926.
- `licencia` usa el ZIP de origen si tiene cinco dígitos; no imputar uno por cercanía ni añadir ceros a valores inválidos. `license_id` es el hash de `license_number` y `animal_name`, exclusivamente. La unicidad por `license_number` señala variantes; no elegir una a ciegas ni afirmar que se guardan vigencias. Un CP válido de licencias puede estar en `postal_codes` sin geometría.

## Entorno y procedimientos

El nombre técnico es `my_new_project`, el perfil local `default` y `dbt_utils` está fijado en 1.4.1. `DBT_BRONZE=DEV_BRONZE` y `DBT_SILVER=DEV_SILVER` son explícitos en DEV y se necesitan incluso para parsear una selección parcial. `--target` no las cambia. `RAW` y `STG` están en Bronze; `SILVER`, en Silver. `generate_schema_name` respeta los esquemas configurados, no los aísla con el nombre del target. Si se prueba en una base aislada, comprobar también el destino de staging para no reemplazar las vistas DEV ni escribir en RAW. PRE y PRO requieren bases y permisos propios.

Las comprobaciones locales recientes usaron dbt Core 1.12.7 y dbt-snowflake 1.12.5. No asumir que el otro equipo tenga las mismas versiones o que necesite instalarlas si se usa Studio. Para Core, configurar `~/.dbt/profiles.yml` fuera del repositorio. No copiar credenciales a Git, Markdown ni chat. El [runner de integración](tests/integration/arrest_merge_check.py) necesita el conector, PyYAML, dbt-snowflake y una conexión Snowflake con JWT configurada externamente (`SNOWFLAKE_CONNECTION_NAME`, por defecto `civica`; `DBT_BIN` permite indicar el ejecutable). Crea y elimina su propio esquema de prueba con datos sintéticos; no ejecuta `--full-refresh` ni prueba el CRS real.

### Ingesta y datos locales

- `Datos_ejemplo/` está ignorada y no llega con el clon. Los modelos leen Snowflake, nunca esos CSV. No subir la carpeta a Git.
- `scripts/`, `systemd/` y `requirements.txt` pertenecen a la ingesta externa documentada en sesiones anteriores y no están en este checkout. `batch_crimes.py` y `batch_arrests.py` usaban `batch_common.py` para descargar cambios de Seattle Open Data, comparar hashes y multiplicidades en SQLite y subir gzip a `DEV_BRONZE.RAW.STG_SEATTLE_BATCH/`. No reflejan bajas ni automatizan licencias o cartografía. No asumir que la automatización se restaura al clonar.
- Si se trabaja con esa copia, preservar `scripts/state/` y los pendientes. `--inicial` y `--inicial-web` registran el estado base, no suben RAW; no reinicializar entre cargas ni asumir que la base web coincide con lo ya cargado. `run_daily.sh` preparaba ambos conjuntos en paralelo con su entorno del conector, no con dbt. La programación documentada era a las 03:00 locales para los scripts, con reintentos, y una task esperada a las 04:00; no se ha comprobado que ambas estén activas ni la zona horaria efectiva de la task.

## Por dónde retomar

1. **Resolver el choque de `officer_id`.** El test `not_null` de `stg_arrests.officer_id` rechaza un caso que la consolidación acepta y que el runner incluye deliberadamente. No quitar el escenario de integración para disimular el problema. Acordar si el dato ausente en staging se permite o se notifica sin bloquear el build.
2. **Confirmar el CRS policial y validar en Snowflake DEV aislado.** Empezar por `dbt deps` y `dbt parse`; ejecutar integración de arrestos y el `dbt build` de staging/Silver en un destino verificado. Los catálogos que dependen del hecho, como `cad_profiles`, deben quedar en la selección si se quieren actualizar. Verificar también las referencias de categorías, los perfiles CAD, los estados de CP y los `delete+insert` con una segunda ejecución sin novedades.
3. **Si ya existe un esquema Silver antiguo, preparar la migración antes de escribir.** Revisar columnas y claves de `arrest`, `agents` y `subject`, y coordinar la reconstrucción con `cad_profiles` y los consumidores. Mantener `on_schema_change='fail'`. No lanzar `--full-refresh` ni operaciones destructivas sin autorización, verificación de RAW y respaldo de destinos. Si no existe la tabla, basta la primera carga normal.
4. **Dejar abiertas las decisiones que no se han tomado:** grano definitivo de `crimes`, posibles snapshots o vigencias y diseño Gold. No presentar propuestas como implementaciones ni resultados de DuckDB como pruebas nativas de Snowflake.

Preferencias del proyecto: revisar datos y SQL antes de cambiar el diseño, mantener las soluciones incrementales simples y no reintroducir los 42 usos de `normalized_text` que se retiraron. Modificar otros Markdown o el diagrama solo si se pide; cuando se actualice el diagrama, conservar el DBML completo y el estilo visual del SVG.
