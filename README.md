# Civica Project

Proyecto dbt sobre Snowflake con delitos, arrestos y licencias de mascotas de Seattle. Su conexión por código postal (CP) es **únicamente geográfica**: no vincula animales o personas con hechos policiales.

## Estado actual

- **Bronze:** cuatro fuentes declaradas en `models/bronze/`: `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. dbt no crea ni carga estas tablas RAW.
- **Staging:** cuatro modelos configurados como vistas. Las cuatro vistas ya existen en Snowflake; la última normalización local todavía debe publicarse mediante dbt.
- **Silver:** primeros tres modelos SQL/YAML creados, configurados como tablas: `police_add`, `arrest_types` y `licencia`. Su SQL se ha comprobado con consultas en Snowflake, pero **no consta todavía un `dbt build` satisfactorio de esta versión ni su despliegue como tablas**.
- **Pendiente:** resto de Silver, enriquecimiento espacial y Gold.

Referencias: [contexto para continuar](contexto.md), [diccionario y DBML](docs/silver_diagram.md) y [diagrama SVG](docs/Silver_Diagram_actualizado.svg). El diseño de referencia tiene 15 tablas, 82 columnas y 16 relaciones 1:N; aún no recoge `license_id`, añadido después al modelo de licencias. Para lo implementado prevalecen el SQL y el YAML. `docs/fallos.md` y `docs/codigo_postal.md` conservan revisiones antiguas.

## Capas y normalización

| Capa | Base configurada | Esquema | Materialización |
| --- | --- | --- | --- |
| Fuentes Bronze | `DBT_BRONZE` | `RAW` | Tablas cargadas externamente |
| Staging | `DBT_BRONZE` | `STG` | Vistas |
| Silver | `DBT_SILVER` | `SILVER` | Tablas |

`DBT_BRONZE` y `DBT_SILVER` son variables de entorno obligatorias, sin valor predeterminado; no dependen de `target.name`. `DBT_GOLD` aún no se utiliza. La macro `generate_schema_name` respeta los esquemas explícitos sin añadirles el prefijo del perfil.

Staging convierte tipos, recorta espacios exteriores, transforma vacíos y marcadores conocidos en `NULL` y unifica en mayúsculas los textos descriptivos y códigos: áreas policiales, categorías, descripciones, datos demográficos, direcciones visibles, nombres de animales, especies, razas y atributos postales. `arrest_type` también unifica espacios internos, tabulaciones y saltos de línea.

**Excepciones deliberadas:** los identificadores de origen, `source_file`, `batch_id` y `boundary_version` conservan su escritura. No se deben alterar identidades ni rutas por cambiar mayúsculas. Staging conserva metadatos e `is_location_redacted` y **no elimina filas, duplicados ni asociaciones**. Los marcadores `-` de los campos demográficos del sujeto ya se convierten en `NULL`.

## Primeros modelos Silver

| Modelo | Grano y transformación | Clave generada |
| --- | --- | --- |
| `police_add` | Combina delitos y arrestos; una fila por `(precinct, sector, beat)`. Conserva áreas parciales y excluye combinaciones totalmente nulas. | `police_area_id`: hash de los tres campos |
| `arrest_types` | Un tipo de arresto distinto y no nulo, sin repetir la limpieza de staging. | `arrest_type_id`: hash de `description` |
| `licencia` | Elimina duplicados exactos de negocio y registros sin número de licencia. Solo conserva CP de cinco dígitos; un CP inválido queda nulo sin perder la licencia. | `license_id`: hash de `license_number` y `animal_name` |

En `licencia` se ignoran los metadatos de carga al deduplicar. `DISTINCT` compara todos los atributos seleccionados, no solo el número: si una licencia trae datos diferentes, se conservan las variantes y fallan las pruebas de unicidad. No se elige una «última versión» arbitrariamente.

El grano actual sigue siendo **una fila por `license_number`**, con pruebas de unicidad tanto para ese campo como para `license_id`. Un cambio de nombre normalizado genera otra clave, pero esto **no implementa un snapshot ni un histórico temporal**. Fecha, especie, razas y CP no intervienen en ese hash. Al publicar la nueva normalización de nombres, pueden cambiar los `license_id` calculados anteriormente.

La referencia correcta de licencias es `ref('stg_pet_licenses')`. La relación con `Postal_codes` se añadirá cuando exista ese modelo. La propagación de trazabilidad a Silver sigue pendiente.

## Pruebas y validación

- **37 data tests declarados:** 21 en staging y 16 en Silver. Incluyen no nulidad, unicidad, formato postal y reglas de combinación de áreas policiales. Los genéricos multicolumna no son tests singulares.
- **11 unit tests:** seis en `models/staging/_stg_unit_tests.yml` y cinco en `models/silver/_silver_models.yml`, todos con `description`. Comprueban limpieza, conservación de filas en staging, deduplicación, nulos, CP, conflictos y claves. Sus entradas simuladas de Silver representan valores ya normalizados.
- Por decisión del usuario, se eliminaron las **42 aplicaciones de `normalized_text` y su definición**. La normalización SQL y los unit tests se mantienen; no añadir automáticamente un data test de mayúsculas a cada columna.

En la revisión del **19 de noviembre de 2026**, el SQL actualizado se evaluó mediante consultas de solo lectura en Snowflake:

| Modelo | Filas calculadas |
| --- | ---: |
| `stg_crimes` | 1.579.028 |
| `stg_arrests` | 147.187 |
| `stg_pet_licenses` | 38.413 |
| `stg_zipcode_areas` | 273 |
| `police_add` | 162 |
| `arrest_types` | 13 |
| `licencia` | 38.410 |

Las 37 reglas de datos no mostraron incumplimientos y los 11 casos unitarios se comprobaron como consultas SQL. También se verificó la normalización de 42 campos y la conservación de los recuentos RAW en staging. **No se ejecutó el runner nativo de tests de dbt ni se crearon o reemplazaron vistas/tablas con estas consultas.** Falta validar compilación, permisos, materializaciones y tests conjuntamente con `dbt build`.

Se revisó directamente `DEV_BRONZE.RAW.PET_LICENSES`: 38.413 filas, 38.410 números distintos, ninguno vacío y solo tres licencias repetidas (`8065122`, `8070768`, `8070770`). Cada una aparece dos veces con todos sus atributos de negocio idénticos; no hay nombres o especies contradictorios. Esto no garantiza futuras cargas.

## Decisiones pendientes del resto de Silver

- **Grano policial:** en los CSV iniciales había 1.575.312 filas de delitos y 145.625 de arrestos. Dos delitos repetían ID por tipo de tiroteo y 25.352 arrestos repetían ID por infracciones. No se encontraron atributos base contradictorios en aquella muestra; esos recuentos no describen las cargas posteriores. Extraer `Crime_shooting_types` y `Arrest_offenses` antes de deduplicar y conservar `nibrs_description` en el detalle.
- **Temporalidad:** agentes y sujetos quedan pendientes de consultar con los profesores. El posible snapshot de licencias tampoco está implementado.
- **Sujetos sin identificador:** conservar el arresto con `subject_key = NULL`, sin sujeto ficticio ni `subject_status`. `Subject` solo incluirá sujetos identificados, con `sk_person` obligatorio. En la muestra inicial había 71 arrestos sin identificador; no es un recuento actualizado.
- **Informes:** validar la correspondencia entre los distintos formatos de `report_number` antes de construir `Reports`; no unirlos por una normalización no aprobada.
- **Ubicaciones y trazabilidad:** concretar identidad de ubicaciones, distinción entre coordenadas ausentes e inválidas y procedencia de las filas Silver.

### Enriquecimiento postal acordado

La cartografía de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) ya está cargada en RAW y tiene staging: 273 entidades y 251 CP distintos. Se exportó en EPSG:4326; la capa nativa usa EPSG:2926.

`Postal_codes` tendrá una fila por CP, con sus piezas geográficas unidas y una única versión activa. Incluirá CP de licencias sin geometría local. Las licencias usarán su CP de origen; delitos y arrestos accederán al CP mediante `Full_address`.

Solo una coincidencia interior única permitirá `cp_status = 'matched'` y CP no nulo. Los demás estados serán `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Se usarán `ST_MAKEPOINT(longitude, latitude)`, `ST_COVERS` y `ST_CONTAINS`, conservando `decimal(18,12)` y confirmando antes el CRS policial. No reconstruir ubicaciones ocultadas, imputar el CP más cercano ni completar CP inválidos.

No se guardará otra tabla de asignaciones ni un histórico por ubicación; al cambiar el mapa activo se recalcularán las asignaciones. La cobertura exploratoria inicial del 74,41 % en delitos y 98,34 % en arrestos procede de un análisis local de filas, no de Snowflake ni de entidades únicas.

## Ingesta local

`scripts/` contiene descargas por lotes de delitos y arrestos desde Seattle Open Data. Compara hashes y multiplicidades con un histórico acumulado en SQLite, prepara CSV comprimidos y los sube a `DEV_BRONZE.RAW.STG_SEATTLE_BATCH`. No propaga eliminaciones del origen ni cubre licencias o cartografía.

`run_daily.sh` prepara ambos conjuntos en paralelo y los sube después. Las unidades de `systemd/` definen ejecución a las 03:00 locales, recuperación de ejecuciones perdidas y reintentos cada cinco minutos ante fallos, con diagnóstico y aviso. **No se ha verificado aquí que estén instaladas/activas ni el estado de la task de Snowflake que los scripts esperan a las 04:00.**

Los scripts usan `.venv/` y `requirements.txt`, que instala el conector Snowflake, no dbt Core. Conservar `scripts/state/`; no reinicializarlo entre cargas. Estado, datos, entorno virtual y logs están excluidos por la configuración local de Git. La ingesta (`scripts/`, `systemd/` y `requirements.txt`) y los cambios locales de `.gitignore` quedan fuera del commit de normalización y Silver: no basta con clonar el repositorio en otro equipo para disponer de esa automatización.

## Ejecución y siguiente paso

En dbt Studio, usar el entorno de desarrollo y comprobar `DBT_BRONZE=DEV_BRONZE` y `DBT_SILVER=DEV_SILVER`. Ambas variables son necesarias al parsear el proyecto completo. El rol necesita lectura de RAW y permisos para crear vistas en `DEV_BRONZE.STG` y tablas en `DEV_SILVER.SILVER`, además de acceso al warehouse. No empezar en PRE o PRO.

```bash
dbt deps
dbt parse
dbt build --select path:models/staging path:models/silver
```

`packages.yml` fija `dbt_utils` 1.4.1. Para ejecutar desde Studio no hace falta instalar dbt localmente. Si se usa dbt Core, configurar el perfil `default` fuera del repositorio y exportar ambas variables en la terminal; las variables de Studio no se heredan localmente. No guardar credenciales en Git.

**Siguiente paso:** confirmar ese build y, si pasa, continuar Silver tabla a tabla. `Postal_codes` puede abordarse sin esperar la decisión sobre la temporalidad de agentes y sujetos. El [contexto](contexto.md) recoge las precauciones para retomar.
