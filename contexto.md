# Civica Project — contexto para continuar en el portátil

Proyecto de dbt sobre Snowflake que prepara datos de delitos, arrestos y licencias de mascotas de Seattle. La relación entre los datos policiales y las licencias es **geográfica, por código postal (CP)**; no vincula mascotas o personas con hechos policiales.

## Punto de partida

- Repositorio: [Pkenblo/Civica_Project](https://github.com/Pkenblo/Civica_Project). Último commit publicado en `main` al preparar este contexto: `09f1bb5` (`fix: usar DBT_BRONZE para fuentes y staging`).
- `models/bronze/` declara cuatro fuentes en `RAW`: `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. Declararlas en dbt no crea ni carga las tablas.
- `models/staging/` contiene cuatro vistas en `STG`: `stg_crimes`, `stg_arrests`, `stg_pet_licenses` y `stg_zipcode_areas`. Staging normaliza nombres, tipos y marcadores, pero no descarta filas ni resuelve el grano.
- Las cuatro fuentes y vistas usan `env_var('DBT_BRONZE')`, sin valor por defecto. Ya no dependen de `target.name`. `DBT_SILVER` y `DBT_GOLD` están configuradas por el usuario en dbt, pero el código aún no las usa porque **Silver y Gold no están implementadas**.
- Se comprobó localmente con `dbt parse` que `DEV_BRONZE`, `PRE_BRONZE` y `PRO_BRONZE` dirigen las fuentes a `RAW` y las vistas a `STG`, y que la ausencia de `DBT_BRONZE` da error. El modelo postal y sus seis pruebas compilaron localmente; no consta un `dbt build` satisfactorio en Snowflake.

## Requisitos y arranque en el portátil

**Para editar con OpenCode y ejecutar desde dbt Studio:** Git, acceso al repositorio, OpenCode configurado en el portátil y acceso al proyecto en dbt Studio. No hace falta instalar Python ni dbt Core para que el build de Studio se ejecute. Actualizar `main` antes de probar el cambio.

En dbt Studio, comprobar que el entorno de desarrollo usa la conexión de Snowflake adecuada y `DBT_BRONZE=DEV_BRONZE`. PRE y PRO deben usar sus propias bases; no se ha comprobado que tengan las tablas RAW cargadas. El rol necesita acceso al warehouse, lectura de `RAW` y permisos para crear vistas en `STG`.

```bash
dbt deps
dbt build --select stg_zipcode_areas
```

Si funciona, ejecutar `dbt build --select path:models/staging` para validar los cuatro modelos. No lanzar el primer build en PRE o PRO. `packages.yml` fija `dbt_utils` 1.4.1; `dbt deps` lo instala.

**Para ejecutar dbt Core localmente, si se necesita:** instalar Python, pip y el adaptador Snowflake. En el otro equipo se comprobó Python 3.14.8 con `dbt-core==1.12.7` y `dbt-snowflake==1.12.5`. El usuario prefirió una instalación de usuario sin `venv`; en Linux, si el Python del sistema bloquea `pip --user`, consultar antes de cambiar el método de instalación. No hace falta replicar el entorno local si se va a usar Studio.

- El nombre técnico del proyecto es `my_new_project` y el perfil de dbt Core es `default`. Configurar `~/.dbt/profiles.yml` fuera del repositorio, con el método de autenticación y los permisos correspondientes. No copiar credenciales a Git, al Markdown ni al chat.
- En una terminal Bash, usar `export DBT_BRONZE=DEV_BRONZE`; las variables de Studio no se heredan en una terminal local. Comprobar `dbt --version`, `dbt debug` y `dbt deps` antes de lanzar el mismo build.
- VS Code es opcional. `.vscode/settings.json` usa `jinja-sql`, Power User for dbt y sqlfmt manual. La ruta fija `/usr/bin/python3.14` y la del formateador corresponden al otro equipo; ajustarlas solo si se van a usar y no existen en el portátil.

### Archivos de datos locales

`Datos_ejemplo/` está en `.gitignore`: **no llega con el clon**. Los modelos dbt leen Snowflake, no esa carpeta. Copiarla al portátil solo si se va a repetir el análisis local. Contiene `SPD_Crime_Data__2008-Present.csv`, `SPD_Arrest_Data.csv`, `Seattle_Pet_Licenses.csv` y `GeoJSON.json` (unos 418 MB en total). No añadirla a Git; el CSV de delitos supera el límite de GitHub. Los scripts exploratorios temporales del otro equipo tampoco forman parte del repositorio.

## Cartografía postal: qué está hecho

- Fuente: [Zipcodes for King County and Surrounding Area](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area). [Descarga GeoJSON en EPSG:4326](https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ZIPCODE_AREA_113/FeatureServer/0/query?where=1%3D1&outFields=OBJECTID%2CZIPCODE%2CZIP_TYPE%2CCOUNTY_NAME%2CPREFERRED_CITY&returnGeometry=true&outSR=4326&orderByFields=OBJECTID&resultOffset=0&resultRecordCount=2000&f=geojson). La capa se publica originalmente en EPSG:2926; no usar esas coordenadas como longitud y latitud.
- El GeoJSON local se comprobó: **273 entidades, 273 `OBJECTID` distintos y 251 CP distintos**. El usuario confirmó la carga en `DEV_BRONZE.RAW.ZIPCODE_AREAS` desde el stage `DEV_BRONZE.RAW.STG_SEATTLE_INITIAL_LOAD`. No es una semilla ni hay que repetir la carga al cambiar de equipo.
- Bronze guarda una entidad por fila en `FEATURE` (`VARIANT`), `BOUNDARY_VERSION`, `_INGESTED_AT`, `_SOURCE_FILE` y `_BATCH_ID`. `stg_zipcode_areas` extrae sus atributos, convierte con `TRY_TO_GEOGRAPHY` y conserva las piezas, versiones y metadatos. Sus pruebas comprueban campos obligatorios, CP de cinco dígitos y unicidad de `(boundary_version, object_id)`; una geometría no convertible queda nula y falla la prueba.
- Para probar el primer build, comparar el recuento de `RAW.ZIPCODE_AREAS` y `STG.STG_ZIPCODE_AREAS` para la versión cargada. No asumir que el mapa pasa las pruebas espaciales solo porque el GeoJSON tenga la estructura esperada.

## Diseño Silver acordado

- **Referencias:** [diccionario y DBML completo](docs/silver_diagram.md) y [SVG](docs/Silver_Diagram_actualizado.svg). El diseño tiene 15 tablas, 82 columnas y 16 relaciones 1:N. `docs/fallos.md` y `docs/codigo_postal.md` recogen revisiones antiguas. El `README.md` aún menciona tres vistas y `target.name`; para el estado implementado prevalece el código.
- **Grano:** una fila por `offense_id`, `arrest_number` y `license_number`. En los CSV, solo dos delitos repiten ID y cambian en tipo de tiroteo; 25.352 arrestos repiten ID por infracciones; las licencias tienen tres duplicados exactos. Extraer `Crime_shooting_types` y `Arrest_offenses` antes de deduplicar. Mantener `nibrs_description` en el detalle. No elegir una «última versión» sin evidencia; añadir pruebas para detectar atributos base contradictorios en futuras cargas.
- **Sujetos:** `Subject` solo incluye sujetos identificados; `sk_person` sigue siendo obligatorio. Cuando el origen no da identificador, conservar el arresto con `subject_key = NULL`, sin sujeto ficticio ni `subject_status`. Hay 71 arrestos en ese caso. Si el origen trae ID pero falta el registro correspondiente en `Subject`, es un problema de integridad.
- **CP:** `Postal_codes` tendrá una fila por CP, con la geometría unida de una única versión activa. Puede incluir CP de licencias sin geometría local. Las licencias usan su CP de origen; delitos y arrestos llegan mediante `Full_address`. No usar un catálogo calle→CP: los bloques y cruces son aproximados y las calles atraviesan varias zonas.
- **Asignación espacial:** confirmar el CRS policial y conservar la precisión de staging. Dar prioridad a `is_location_redacted`; no reconstruir ubicaciones ocultadas ni imputar el CP más cercano. Solo una coincidencia interior única da `cp` con `cp_status = 'matched'`. En los demás estados, `cp` queda nulo: `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. El cruce se hará con `ST_MAKEPOINT(longitude, latitude)`, `ST_COVERS` y `ST_CONTAINS`. No guardar otra tabla de asignaciones ni histórico por ubicación; al cambiar el mapa activo, recalcular. La prueba local dio un CP único al 74,41 % de las filas de delitos y al 98,34 % de arrestos; no son cifras de Snowflake ni de entidades únicas.

## Por dónde retomar

1. Confirmar el resultado de `dbt build --select stg_zipcode_areas` en desarrollo y después validar el resto de staging. Si falla, mirar el error y los datos antes de cambiar el diseño.
2. Al empezar Silver, configurar su base con `DBT_SILVER`. Se puede empezar por `Postal_codes` sin esperar la decisión sobre la temporalidad de agentes y sujetos, aplazada hasta hablar con los profesores. Quedan por concretar la identidad de las ubicaciones, la distinción entre coordenadas ausentes e inválidas y la trazabilidad en Silver.
3. Antes de construir `Reports`, validar la correspondencia de `report_number`: delitos y arrestos tienen formatos distintos y no coinciden tal cual. Una normalización exploratoria dio 83.432 coincidencias de 84.963 números distintos de arrestos; no es todavía una regla aprobada. Las licencias traen 122 CP vacíos y 3 de cuatro dígitos; no completar por suposición. En staging de arrestos queda un ajuste menor detectado, no aplicado: los campos demográficos del sujeto aún conservan el marcador `-`.

**Criterio de trabajo:** revisar datos, SQL y diagrama antes de llamar «error» a algo. Distinguir los fallos comprobados de las decisiones pendientes. No modificar otros `.md` sin petición expresa, en particular `docs/fallos.md`. Si se modifica el diseño por encargo, conservar el bloque DBML completo para dbdiagram.io y no presentar Silver como implementada hasta que exista y se pruebe.
