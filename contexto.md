# Civica Project — contexto para retomar

Proyecto dbt sobre Snowflake para delitos, detenciones, licencias de mascotas y cartografía postal de Seattle. La comparación por CP es **geográfica**, no una relación entre mascotas, personas y hechos policiales. Para los contratos vigentes, consultar la [memoria de Silver](docs/silver.md) y la [guía de Gold](docs/gold.md); este archivo resume cómo retomar el trabajo.

**Punto de relevo:** Silver queda cerrada en código y documentación. Sobre Gold ya están definidos los [tres marts de delitos y licencias](docs/marts.md). Se comprobó su lógica con datos sintéticos locales. Está pendiente el `dbt build` integral con datos reales en Snowflake DEV.

## Qué hay y qué se ha comprobado

- Repositorio: [Pkenblo/Civica_Project](https://github.com/Pkenblo/Civica_Project). Consultar `git status` y `git log` al retomar: puede haber trabajo local sin commit. No descartarlo ni hacer commits o pushes sin petición.
- **Bronze:** `CRIMES`, `ARRESTS`, `PET_LICENSES`, `ZIPCODE_AREAS`. dbt declara las fuentes; no carga RAW. **Staging:** `stg_crimes`, `stg_arrests`, `stg_pet_licenses`, `stg_zipcode_areas`, todos vistas. Las cuatro vistas existían en el entorno consultado anteriormente; no asumir que estén publicadas con el SQL actual.
- **Silver:** 17 modelos, 96 columnas y 19 relaciones lógicas, recogidos en el [SVG definitivo](docs/silver_diagram.svg) y el [diccionario con DBML editable](docs/silver_diagram.md). Se retiró el SVG anterior. Se comprobaron los enlaces de la documentación y la coherencia entre el SVG, el DBML y los modelos y relaciones declarados en dbt.
- **Gold:** `models/gold/` publica hechos y dimensiones a partir de Silver. No hay snapshots ni vigencias en el alcance actual.
- **Marts:** `models/marts/` agrega los datos de Gold por CP y año en `DBT_GOLD.MARTS`. Los tres indicadores son robos de vehículos (`240`), atracos y hurtos (`120`, `23A`, `23B`, `23H`) y delitos con etiqueta de tiroteo o código de homicidio (`09A`, `09B`, `09C`). Se comparan con licencias emitidas de perro, gato, cabra y cerdo.
- **Qué no se ha comprobado:** el cierre documental no ejecutó dbt contra Snowflake. La [regresión histórica del `MERGE`](docs/arrest_incremental.md#validación-de-la-implementación-inicial-del-merge) se hizo en un esquema aislado y no valida el incremental vigente. El [runner sintético actual](tests/integration/arrest_delete_insert_check.py) y los datos reales son comprobaciones distintas.

## Contratos que hay que conservar

### Staging y fuentes

Normalizar tipos, espacios, vacíos y marcadores en staging. Los textos descriptivos y los códigos se publican en mayúsculas; `arrest_type` también unifica espacios internos. No alterar la escritura de IDs de origen, `source_file`, `batch_id` ni `boundary_version`: en los datos revisados había números de licencia alfanuméricos con minúsculas. Staging conserva todas las filas y asociaciones. Las coordenadas se publican con cinco decimales (`NUMBER(18,5)`) y se evalúan marcadores y rangos antes de redondear. Mantener la distinción entre valores ausentes, inválidos y ocultados. Los fixtures unitarios de Silver deben representar entradas ya normalizadas; dbt no ejecuta upstream dentro de esas pruebas.

### Delitos e informes

- `crimes` publica la última versión por pareja `(report_id, offense_id)`. Un mismo `offense_id` puede aparecer en varios informes. `crime_shooting_types` conserva los tipos observados en staging y se une por `crime_id`. `reports` recoge números de ambos orígenes; staging de arrestos convierte únicamente `YYYY0000NNNNNN` a `YYYY-NNNNNN`. La fecha del informe procede solo de delitos. Un informe compartido no identifica un vínculo particular delito–detención.
- `crimes` guarda `offense_category_id` y `offense_subcategory_id`. `offense_subcategories` distingue la etiqueta dentro de su categoría; si solo se informa la etiqueta, el padre queda nulo. Mantener ambos IDs en el hecho permite conservar una categoría sin subcategoría. `nibrs` es otra clasificación y no debe ser el camino obligatorio para obtener la categoría. En el CSV local: 3 categorías, 31 subcategorías, 64 códigos NIBRS informados y 1.643 filas con categoría pero sin código.

### Detenciones

- `arrest` usa `delete+insert` por `arrest_number`. Los nulos reemplazan los valores anteriores y una ubicación `REDACTED` no recupera atributos de otras versiones. No se propagan bajas de RAW.
- `agents` y `subject` mantienen una fila por `officer_id` y `sk_person`, respectivamente. Las claves se derivan solo de esos IDs; un ID ausente en la detención deja la referencia nula. Las edades siguen en `arrest`: `officer_age` y `subject_age_range`.
- `arrest_offenses` conserva los cargos por tipo y descripción NIBRS observados, sin inferir código. `cad_profiles` se construye desde staging y `arrest.cad_profile_id` es nulo si faltan los tres atributos CAD.

### Incrementales y reconstrucción de catálogos

Solo `arrest`, `crimes` y `licenses` son incrementales en Silver. Cada uno usa [`after_max_ingested_at`](macros/utils/after_max_ingested_at.sql) para filtrar por `ingested_at` estrictamente mayor que el máximo de su propio destino; el corte no es por clave. Las ingestas anteriores o iguales al máximo se omiten aunque sean altas nuevas. Las pruebas `*_source_ids_complete` contrastan la cobertura y la última ingesta con staging. La primera construcción y `--full-refresh` no aplican el corte; una tabla existente vacía necesita reconstrucción porque su máximo es `NULL`. Los otros 14 modelos se reconstruyen como tablas; no usan `changed_catalog_rows`. Los puentes conservan lo observado en staging para eventos publicados, no asociaciones necesariamente vigentes.

### Geografía y licencias

- `police_add` usa `(precinct, sector, beat)` y conserva áreas parciales. `address_id` no depende del CP, de `cp_status` ni de la versión postal; no cambiar por separado el contrato de ubicación de los hechos y `full_address`. `full_address` asume EPSG:4326 sin variable de confirmación y solo publica CP ante una coincidencia interior única. Al cambiar el mapa, reconstruir `postal_codes` y `full_address` juntos.
- `postal_codes` une las piezas de una única versión y valida cantidad, IDs, CP y geometrías. La versión por defecto es `kingcounty_download_2026-11-19` y el recuento esperado son 273 entidades; para otro mapa, configurar `zipcode_boundary_version` y `zipcode_expected_feature_count` conjuntamente. El GeoJSON de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) se exportó a EPSG:4326 y el usuario confirmó su carga en `DEV_BRONZE.RAW.ZIPCODE_AREAS`; no repetirla por defecto. La capa nativa usa EPSG:2926.
- `licenses` conserva la última fila por `license_number`. Usa el ZIP de origen si tiene cinco dígitos; no imputar uno por cercanía ni añadir ceros a valores inválidos. `license_id` es el hash de `license_number` y `animal_name`, exclusivamente. No se guardan vigencias. Un CP válido de licencias puede estar en `postal_codes` sin geometría.

## Entorno y procedimientos

El nombre técnico es `my_new_project`, el perfil local `default` y `dbt_utils` está fijado en 1.4.1. `DBT_BRONZE=DEV_BRONZE` y `DBT_SILVER=DEV_SILVER` son explícitos en DEV y se necesitan incluso para parsear una selección parcial. Para construir Gold, fijar también `DBT_GOLD=DEV_GOLD`. `--target` no cambia estas variables. `RAW` y `STG` están en Bronze; `SILVER`, en Silver; `GOLD`, en Gold. `generate_schema_name` respeta los esquemas configurados, no los aísla con el nombre del target. Si se prueba en una base aislada, comprobar también el destino de staging para no reemplazar las vistas DEV ni escribir en RAW. PRE y PRO requieren bases y permisos propios.

Las comprobaciones locales recientes usaron dbt Core 1.12.7 y dbt-snowflake 1.12.5. No asumir que el otro equipo tenga las mismas versiones o que necesite instalarlas si se usa Studio. Para Core, configurar `~/.dbt/profiles.yml` fuera del repositorio. No copiar credenciales a Git, Markdown ni chat. El [runner de integración](tests/integration/arrest_delete_insert_check.py) necesita el conector, PyYAML, dbt-snowflake y una conexión Snowflake con JWT configurada externamente (`SNOWFLAKE_CONNECTION_NAME`, por defecto `civica`; `DBT_BIN` permite indicar el ejecutable). Crea y elimina su propio esquema de prueba con datos sintéticos; el `--full-refresh` del runner se limita a ese esquema y no valida el CRS real.

### Ingesta y datos locales

- `Datos_ejemplo/` está ignorada y no llega con el clon. Los modelos leen Snowflake, nunca esos CSV. No subir la carpeta a Git.
- El [catálogo de códigos NIBRS](datos_ejemplo/Todos_los_crimenes.csv) sí está versionado, en `datos_ejemplo/` con minúscula. Sirve de referencia para los indicadores; no interviene en la ejecución de dbt.
- `scripts/`, `systemd/` y `requirements.txt` se documentaron como parte de la ingesta externa y no están versionados en Git. `batch_crimes.py` y `batch_arrests.py` usaban `batch_common.py` para descargar cambios de Seattle Open Data, comparar hashes y multiplicidades en SQLite y subir gzip a `DEV_BRONZE.RAW.STG_SEATTLE_BATCH/`. No reflejan bajas ni automatizan licencias o cartografía. No asumir que la automatización se restaura al clonar.
- Si se trabaja con esa copia, preservar `scripts/state/` y los pendientes. `--inicial` y `--inicial-web` registran el estado base, no suben RAW; no reinicializar entre cargas ni asumir que la base web coincide con lo ya cargado. `run_daily.sh` preparaba ambos conjuntos en paralelo con su entorno del conector, no con dbt. La programación documentada era a las 03:00 locales para los scripts, con reintentos, y una task esperada a las 04:00; no se ha comprobado que ambas estén activas ni la zona horaria efectiva de la task.

## Por dónde retomar

1. **Si ya existe un esquema Silver antiguo, preparar la migración antes de escribir.** Revisar columnas, claves y nombres, y coordinar la reconstrucción con los consumidores. No lanzar `--full-refresh` ni operaciones destructivas sin autorización, verificación de RAW y respaldo de destinos. Si no existe la tabla, basta la primera carga normal.
2. **Validar Silver en Snowflake DEV.** Primero correr la regresión sintética en su esquema aislado. Después seguir la [ejecución de Silver en DEV](docs/silver.md#ejecución-en-dev) y, con los destinos y el mapa comprobados, ejecutar `dbt build --target dev --select '+path:models/silver'`. Revisar cobertura por clave y última ingesta, preservación de cargos y etiquetas, distribución de `cp_status` y un segundo pase sin novedades. No presentar resultados locales o sintéticos como validación con datos reales.
3. **Validar Gold sobre Silver completo.** Seguir la [guía de Gold](docs/gold.md); no ejecutar la reconciliación de bajas de Gold sobre un Silver incompleto. Los snapshots y las vigencias no forman parte del alcance actual.
4. **Construir y contrastar los marts en DEV.** Con Gold validado, seguir la [guía de ejecución y comprobaciones](docs/marts.md#estado-y-ejecución-en-dev). Revisar los años parciales y la cobertura postal antes de interpretar una correlación.

Preferencias del proyecto: revisar datos y SQL antes de cambiar el diseño, mantener las soluciones incrementales simples y no reintroducir los 42 usos de `normalized_text` que se retiraron. Modificar otros Markdown o el diagrama solo si se pide; cuando se actualice el diagrama, conservar el DBML completo y el estilo visual del SVG.
