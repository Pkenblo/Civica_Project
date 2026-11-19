# Civica Project — contexto para continuar

Actualizado el **19 de noviembre de 2026**. Proyecto de dbt sobre Snowflake que prepara delitos, arrestos y licencias de mascotas de Seattle. La relación entre dominios es **geográfica, por código postal (CP)**; no vincula mascotas o personas con hechos policiales.

## Estado del repositorio y del despliegue

- Repositorio: [Pkenblo/Civica_Project](https://github.com/Pkenblo/Civica_Project). Punto de partida de esta sesión: `7f315da` (`docs: añadir contexto para continuar en el portátil`). La actualización de normalización, Silver, pruebas y documentación se prepara en un único commit; consultar `git log` y `git status` para confirmar el estado del checkout y no descartar trabajo local.
- `models/bronze/` declara cuatro fuentes en `RAW`: `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. Declararlas no crea ni carga las tablas.
- Existen cuatro modelos de vistas en `models/staging/`: `stg_crimes`, `stg_arrests`, `stg_pet_licenses` y `stg_zipcode_areas`. El usuario confirmó que las cuatro vistas ya están creadas en Snowflake y se consultaron durante esta sesión. **Los últimos cambios locales de normalización no se han desplegado mediante dbt.**
- Se ha empezado Silver con tres modelos SQL/YAML en `models/silver/`: `police_add`, `arrest_types` y `licencia`, configurados como tablas. Se evaluó su SQL mediante SELECT en Snowflake; **no consta un `dbt build` satisfactorio de esta versión ni la creación de estas tablas por dbt**. El resto de Silver y Gold siguen pendientes.
- Fuentes y staging usan `env_var('DBT_BRONZE')`; Silver ya usa `env_var('DBT_SILVER')`. Ambas son obligatorias y no dependen de `target.name`. Los esquemas explícitos son `RAW`, `STG` y `SILVER`, respectivamente. `DBT_GOLD` aún no se utiliza.
- El commit solicitado incluye `models/silver/`, los cambios de staging, sus unit tests y `README.md`/`contexto.md`. Quedan fuera `scripts/`, `systemd/`, `requirements.txt` y los cambios locales de `.gitignore`, que ya existían al comenzar la sesión. Esa ingesta sigue siendo trabajo local y no viaja con el clon. No hacer nuevos commits o pushes sin petición.

## Normalización de staging acordada

- Staging normaliza nombres de columnas, tipos, espacios exteriores, vacíos y marcadores conocidos, pero **no descarta filas ni resuelve duplicados o asociaciones**.
- Textos descriptivos y códigos en mayúsculas: áreas policiales, categorías y descripciones NIBRS, tipos de arresto/infracción, textos CAD, datos demográficos, direcciones visibles, barrios, nombres de animales, especies, razas y atributos postales. `arrest_type` también unifica espacios internos, tabulaciones y saltos de línea.
- **No cambiar la escritura de identificadores de origen** (`license_number`, `offense_id`, números de informe/arresto, agente o sujeto), ni de `source_file`, `batch_id` o `boundary_version`. Se encontraron tres números de licencia alfanuméricos con minúsculas; no asumir que sus identidades son insensibles al caso.
- Los campos demográficos del sujeto ya convierten `-` o vacío en `NULL`; el ajuste pendiente del contexto anterior está aplicado. Se mantienen los demás marcadores específicos, como `SK_PERSON = -1`.
- Se conservan metadatos de carga e `is_location_redacted`. Las coordenadas mantienen `decimal(18,12)`. No confundir una conversión numérica fallida con una ausencia sin resolver antes esa regla.
- Toda nueva limpieza de textos debe ir en staging, no repetirse en Silver. Los fixtures unitarios de Silver tienen que representar la salida ya normalizada, porque el unit test sustituye sus entradas y no ejecuta los modelos anteriores.

## Tres modelos Silver creados

### `police_add`

- Combina áreas de `stg_crimes` y `stg_arrests` y deduplica por `(precinct, sector, beat)`; un beat no se presupone único por sí solo.
- Conserva combinaciones parciales y excluye las totalmente nulas.
- `police_area_id` se genera con `dbt_utils.generate_surrogate_key` sobre esos tres campos.
- Pruebas: clave no nula/única, combinación de campos única y al menos un campo informado. Las dos pruebas multicolumna son genéricas de `dbt_utils`, no singulares.

### `arrest_types`

- Catálogo de tipos de arresto distintos y no nulos, conservando los textos de staging como `description`.
- `arrest_type_id` es el hash de `description`. Ambas columnas tienen pruebas `not_null` y `unique`.

### `licencia`

- Lee `ref('stg_pet_licenses')`; se corrigió la referencia inexistente `stg_licenses`.
- Excluye números de licencia nulos y elimina duplicados exactos de los atributos de negocio, ignorando los metadatos de carga. `DISTINCT` **no** deduplica solamente por número.
- `cp` conserva el ZIP de origen si tiene cinco dígitos; en otro caso queda nulo, sin perder la licencia, completar ceros ni restringirla a Seattle. El valor original sigue disponible en staging.
- Por petición del usuario, **`license_id` es el hash solo de `license_number` y `animal_name`**, con el nombre ya normalizado en staging. No incluir fecha, especie, razas ni CP en la clave. La columna ya no se llama `license_key`.
- Un cambio de nombre normalizado genera otra clave, pero **no hay snapshot, vigencias ni histórico temporal implementado**. Se conserva el grano actual de una fila por `license_number` y la prueba `unique` de ese campo. Si entran variantes, se conservan para revisión y las pruebas fallan en lugar de seleccionar una versión arbitraria. La futura historización requerirá definir sus propias reglas.
- Tiene ocho columnas, al añadir `license_id` a las siete del diseño original. El diccionario/DBML/SVG aún no se han actualizado con este cambio; no modificarlos sin petición.
- La relación con `Postal_codes` y la propagación de trazabilidad a Silver siguen pendientes. Al publicar nombres en mayúsculas pueden cambiar los hashes calculados anteriormente.

## Pruebas y comprobaciones realizadas

- Quedan **37 data tests**: 21 en staging y 16 en Silver. Cubren no nulidad, unicidad, CP y reglas de áreas.
- Hay **11 unit tests**, seis en `models/staging/_stg_unit_tests.yml` y cinco en `models/silver/_silver_models.yml`. Todos tienen `description`, no comentarios de cabecera. Comprueban normalización y marcadores, conservación de filas en staging, deduplicación, áreas parciales, CP, conflictos y claves.
- Un unit test de licencias conserva dos CP distintos de un mismo número: prueba que el SQL no oculta el conflicto. Puede pasar aunque los data tests de unicidad fallen sobre ese ejemplo. No confundir ambos propósitos.
- **Preferencia explícita del usuario:** se eliminaron las 42 aplicaciones del genérico `normalized_text` y `tests/generic/test_normalized_text.sql`. Mantener el resto de pruebas y la limpieza SQL. No reintroducir tests masivos por columna ni otros equivalentes sin acordarlo.
- Se validó el YAML y se comprobaron los 11 casos unitarios como consultas SQL en Snowflake, sin usar el runner nativo de dbt. También se evaluaron mediante SELECT las 37 reglas de datos sobre el SQL actualizado: **ningún incumplimiento**.
- Se verificaron 42 campos descriptivos/códigos normalizados sin anomalías y el mantenimiento de todos los recuentos RAW en staging. Se consultaron los datos actuales, no únicamente los CSV iniciales.

Resultados calculados en la revisión del 19/11/2026, **no recuentos de nuevas tablas Silver desplegadas**:

| Modelo | Filas |
| --- | ---: |
| `stg_crimes` | 1.579.028 |
| `stg_arrests` | 147.187 |
| `stg_pet_licenses` | 38.413 |
| `stg_zipcode_areas` | 273 |
| `police_add` | 162 |
| `arrest_types` | 13 |
| `licencia` | 38.410 |

Se consultó directamente `DEV_BRONZE.RAW.PET_LICENSES`: 38.413 filas, 38.410 números distintos, ninguno vacío y tres números repetidos dos veces (`8065122`, `8070768`, `8070770`). Son duplicados exactos de todos los atributos de negocio, sin considerar metadatos. No hay números con nombres o especies diferentes ni otros atributos base contradictorios. Esto valida el `DISTINCT` para los datos actuales, no garantiza futuras cargas.

**Falta el build real:** las consultas anteriores no crearon/reemplazaron relaciones ni probaron la compilación completa de dbt, sus materializaciones, permisos y ejecución nativa de tests. No presentar esas comprobaciones como un `dbt build` aprobado.

## Entorno y próxima ejecución

Para editar y ejecutar desde dbt Studio no es necesario instalar Python ni dbt Core localmente. Usar desarrollo, con `DBT_BRONZE=DEV_BRONZE` y `DBT_SILVER=DEV_SILVER`. Ambas variables se necesitan al parsear el repositorio completo, incluso si solo se selecciona staging. PRE y PRO deben tener sus propias bases; no se ha comprobado su carga RAW ni debe hacerse allí el primer build.

El rol de dbt necesita acceso al warehouse, lectura de RAW, creación de vistas en `DEV_BRONZE.STG` y de tablas en `DEV_SILVER.SILVER`. Próxima validación:

```bash
dbt deps
dbt parse
dbt build --select path:models/staging path:models/silver
```

`packages.yml` fija `dbt_utils` 1.4.1. Si falla el build, revisar el error y los datos antes de cambiar el diseño. El nombre técnico sigue siendo `my_new_project`, con perfil local `default`.

Para dbt Core, configurar `~/.dbt/profiles.yml` fuera del repositorio y exportar ambas variables en la terminal; Studio no las hereda a la sesión local. En este portátil hay `.venv/` para el conector de ingesta, **no una instalación de dbt Core**. En el otro equipo se probaron Python 3.14.8, Core 1.12.7 y `dbt-snowflake` 1.12.5, instalados por el usuario sin `venv`; no asumir que están instalados aquí ni cambiar el método sin consultarlo si Python bloquea `pip --user`. VS Code es opcional y sus rutas de Python/formateador corresponden al otro equipo.

No copiar credenciales a Git, Markdown ni chat. `Datos_ejemplo/` está ignorada y no llega con el clon: los modelos leen Snowflake, no esa carpeta. Solo transferirla si se repite el análisis local. Los cuatro archivos originales sumaban unos 418 MB; no añadirlos a Git.

## Ingesta local incorporada al contexto

- `scripts/batch_crimes.py` y `scripts/batch_arrests.py` usan `batch_common.py` para comprobar la versión oficial de Seattle Open Data y descargar el CSV completo cuando cambia. Comparan hashes de filas y multiplicidades contra un histórico acumulado en SQLite y preparan CSV gzip con contenido no observado previamente.
- No es un merge por identificador ni un reflejo de borrados del origen. Conserva multiplicidades máximas observadas y no reenvía una fila desaparecida que luego reaparece.
- Sube a `DEV_BRONZE.RAW.STG_SEATTLE_BATCH/crimes/` o `arrests/`, con pendientes persistidos, nombres reservados y verificación del contenido en reintentos, sin sobrescribir archivos existentes. No automatiza licencias ni cartografía.
- `--inicial`/`--inicial-web` registran una base y no la suben a Snowflake. No reinicializar entre cargas ni asumir que una base web actual equivale a lo cargado previamente en RAW. Conservar `scripts/state/`, que no viaja en Git.
- `scripts/run_daily.sh` usa `.venv/bin/python`, valida el estado, espera red, prepara los dos conjuntos en paralelo y sube después. `requirements.txt` fija `snowflake-connector-python==5.1.0`; no instala dbt.
- Las unidades de `systemd/` definen ejecución a las 03:00 locales, recuperación de ejecuciones perdidas y reintentos cada cinco minutos ante fallos, con diagnóstico/aviso de escritorio. **No se ha comprobado aquí que estén instaladas o activas.** Los scripts esperan una task de Snowflake a las 04:00; su definición, zona horaria y estado no se han verificado.
- `.venv/`, `scripts/state/`, `__pycache__/`, datos y logs están ignorados. No publicar estados ni credenciales. Hay tests de los scripts, pero no confundir su existencia con una validación end-to-end de toda la ingesta.

## Cartografía y diseño pendiente

- Fuente: [Zipcodes for King County and Surrounding Area](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area). [Descarga GeoJSON en EPSG:4326](https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ZIPCODE_AREA_113/FeatureServer/0/query?where=1%3D1&outFields=OBJECTID%2CZIPCODE%2CZIP_TYPE%2CCOUNTY_NAME%2CPREFERRED_CITY&returnGeometry=true&outSR=4326&orderByFields=OBJECTID&resultOffset=0&resultRecordCount=2000&f=geojson). La capa original es EPSG:2926; no interpretar sus coordenadas como longitud/latitud.
- La descarga tenía 273 entidades, 273 `OBJECTID` y 251 CP distintos. El usuario confirmó la carga en `DEV_BRONZE.RAW.ZIPCODE_AREAS` desde `STG_SEATTLE_INITIAL_LOAD`; no repetirla al cambiar de equipo. Bronze conserva `FEATURE` (`VARIANT`), versión y metadatos; staging convierte con `TRY_TO_GEOGRAPHY`, sin unir piezas ni elegir mapa activo.
- Referencias de diseño: [diccionario/DBML](docs/silver_diagram.md) y [SVG](docs/Silver_Diagram_actualizado.svg), con 15 tablas, 82 columnas y 16 relaciones 1:N. El nuevo `license_id` aún no está reflejado allí. `docs/fallos.md` y `docs/codigo_postal.md` son revisiones antiguas, no la especificación vigente.
- **Grano policial:** una fila por `offense_id` o `arrest_number`. En los CSV iniciales (1.575.312 delitos y 145.625 filas de arrestos) dos delitos repetían ID por tipo de tiroteo y 25.352 arrestos repetían ID por infracciones, sin atributos base contradictorios. Son resultados de aquella muestra, no garantías sobre las nuevas cargas. Extraer `Crime_shooting_types` y `Arrest_offenses` antes de deduplicar; conservar `nibrs_description` en el detalle.
- **Sujetos:** solo sujetos identificados en `Subject`, con `sk_person` obligatorio. Sin identificador, conservar el arresto con `subject_key = NULL`; no inventar sujetos ni `subject_status`. Los 71 arrestos sin ID corresponden al análisis inicial, no a un recuento actual. Si hay ID pero falta su sujeto, es un error de integridad.
- **CP:** `Postal_codes` tendrá una fila por CP, piezas unidas en la geometría de una única versión activa y CP de licencias sin geometría si es necesario. Licencias usan su ZIP de origen; delitos/arrestos acceden mediante `Full_address`. No usar un catálogo calle→CP.
- **Asignación espacial:** confirmar el CRS policial y mantener `decimal(18,12)`. Prioridad a `is_location_redacted`. Solo una coincidencia interior única da CP con estado `matched`; en `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`, CP nulo. Usar `ST_MAKEPOINT(longitude, latitude)`, `ST_COVERS` y `ST_CONTAINS`. No reconstruir ubicaciones ocultadas ni imputar el CP más cercano.
- No añadir otra tabla de asignaciones ni histórico por ubicación; recalcular al cambiar el mapa activo. La prueba local inicial encontró un CP único en el 74,41 % de las filas de delitos y el 98,34 % de arrestos: no son cifras de Snowflake ni de entidades únicas.

## Por dónde retomar

1. Confirmar el `dbt build` completo de staging y los tres modelos Silver en desarrollo. Si pasa, continuar tabla a tabla, según indique el usuario; `Postal_codes` puede abordarse sin esperar otras decisiones.
2. Mantener pendientes la temporalidad de agentes y sujetos hasta hablar con los profesores y el posible snapshot de licencias. Concretar identidad de ubicaciones, distinción entre coordenadas ausentes e inválidas y trazabilidad en Silver.
3. Antes de `Reports`, validar la correspondencia de `report_number`: los formatos de delitos y arrestos no coinciden tal cual. Una exploración inicial dio 83.432 coincidencias de 84.963 números distintos de arrestos, pero no es una regla aprobada. En las licencias originales había 122 CP vacíos y tres de cuatro dígitos; no completarlos por suposición.
4. Al construir `Postal_codes`, añadir la prueba de relación desde `licencia.cp` y validar mapa completo, versión activa y geometrías antes del cruce espacial.

**Criterio de trabajo:** revisar datos, SQL y diagrama antes de llamar «error» a algo. Distinguir código local, consultas de comprobación y despliegue real. Mantener cambios graduales, no repetir limpiezas en Silver ni añadir pruebas masivas de normalización sin acordarlo. No modificar otros `.md` sin petición expresa, en particular `docs/fallos.md`. Si se modifica el diseño por encargo, conservar el DBML completo para dbdiagram.io. No presentar el resto de Silver, Gold o los snapshots como implementados, ni un build como aprobado sin ejecutarlo.
