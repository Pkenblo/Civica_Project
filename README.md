# Civica Project

Cívica prepara datos abiertos de Seattle con dbt y Snowflake: delitos, detenciones, licencias de mascotas y cartografía postal. El código postal (CP) permite comparar estos conjuntos por zona. **La relación es geográfica:** compartir CP no vincula una mascota, una persona o una licencia con un hecho policial.

La [guía de Silver](docs/silver.md) describe los 17 modelos, sus claves, la carga incremental y el procedimiento de validación en DEV. El [diccionario y DBML](docs/silver_diagram.md) y el [diagrama](docs/silver_diagram.svg) corresponden al diseño anterior.

La [guía de Gold](docs/gold.md) documenta los hechos, los análisis CP × año y las instrucciones de ejecución. El [diagrama Gold en DBML](gold_diagram.dbml) se puede importar en dbdiagram.io.

## Capas y alcance

| Capa | Dónde | Qué hace |
| --- | --- | --- |
| Bronze | `DBT_BRONZE.RAW` | Declara `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. La carga es externa a dbt. |
| Staging | `DBT_BRONZE.STG` | Cuatro vistas que renombran columnas, convierten tipos y normalizan valores sin resolver duplicados ni eliminar asociaciones. |
| Silver | `DBT_SILVER.SILVER` | Modelos incrementales y tablas que se reconstruyen en cada ejecución. |
| Gold | `DBT_GOLD.GOLD` | Hechos y licencias incrementales; el resto de dimensiones, puentes y dos marts por CP y año se reconstruyen. |

Staging pasa a mayúsculas los textos descriptivos y los códigos, recorta espacios y convierte vacíos y marcadores conocidos en `NULL`. `arrest_type` también unifica espacios internos. Los identificadores y los metadatos de procedencia conservan su escritura. Limpiar aquí, y no en cada modelo Silver, mantiene una sola regla para todos los consumidores. Se conserva `_INGESTED_AT` como `ingested_at`, además del lote y el fichero. Latitud y longitud se publican como `NUMBER(18,5)`; staging evalúa los marcadores y rangos antes de redondear. No se redondean fechas, identificadores ni geometrías postales.

## Delitos: conservar el detalle sin inflar los recuentos

En el CSV inicial se observaron 1.575.312 filas y 1.575.310 parejas distintas de informe y delito. `crimes` publica la última versión de cada pareja. `crime_shooting_types` extrae las asociaciones desde staging, para que un delito pueda tener varios tipos sin repetir el hecho ni perder etiquetas.

`offense_categories` tiene una fila por categoría y `offense_subcategories` una por combinación de categoría y etiqueta. Conservar la categoría en la clave de subcategoría evita mezclar etiquetas iguales si aparecen bajo categorías distintas. El CSV de ejemplo tenía tres categorías y 31 subcategorías, cada una con un solo padre. `crimes` guarda las dos referencias: así conserva una categoría informada aunque falte la subcategoría. Tampoco se inventa una categoría padre cuando llega solo la subcategoría.

**NIBRS se mantiene separado.** Describe un código y su clasificación, no las agrupaciones del dataset. Hay delitos con categoría y sin código NIBRS. El catálogo publica una fila por código con sus últimos atributos recibidos.

## Detenciones: una fila por arresto, varias infracciones si existen

`arrest` publica la última fila por `arrest_number` y reemplaza la anterior con `delete+insert`, incluidos los nulos. No usa `report_id` como clave: un informe puede tener varias detenciones. `agents` y `subject` siguen la misma regla por identificador de persona, con claves estables que no dependen de sus atributos. Las edades del agente y del sujeto siguen en la detención.

`arrest_offenses` conserva cada asociación observada de detención, tipo de infracción y descripción NIBRS. En el CSV inicial había 145.625 filas para 110.143 detenciones. `cad_profiles` reúne las combinaciones de cierre, tipo inicial y prioridad de staging; no identifica llamadas individuales.

Solo `arrest`, `crimes` y `licenses` son incrementales. Los catálogos y puentes son tablas que se reconstruyen en cada ejecución.

## Informes, áreas policiales y código postal

`reports` reúne números de informe de ambos dominios. En arrestos se transforma únicamente el formato aprobado `YYYY0000NNNNNN` a `YYYY-NNNNNN`; el original permanece en RAW. La fecha y hora del informe procede de delitos: no se rellena con la fecha del arresto. Compartir informe no prueba qué arresto corresponde a qué delito; unir los dos hechos por `report_id` puede multiplicar las filas. `police_add` usa la combinación de distrito, sector y beat, porque un beat no se presupone único. Se conservan las áreas parciales.

La cartografía de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) se exportó a EPSG:4326; la capa nativa usa EPSG:2926. La descarga de referencia tenía 273 entidades y 251 CP distintos. `postal_codes` valida un solo mapa activo, une las piezas de cada CP y admite códigos de licencias sin polígono local. Antes de materializar `full_address`, hay que confirmar de forma independiente que las coordenadas **policiales** están en EPSG:4326; la proyección del mapa no demuestra la del origen policial.

`full_address` calcula el CP solo si exactamente una zona cubre el punto y este cae en su interior (`ST_COVERS` y `ST_CONTAINS`, con longitud antes de latitud). Guarda `cp_status`: `matched`, `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Si no hay coincidencia interior única, `cp` queda nulo. No se aproxima al CP más cercano ni se necesita una tabla de asignaciones. La clave de dirección no depende del CP, de su estado ni de la versión del mapa.

`licenses` toma el CP de origen si consta de cinco dígitos. Conserva la última versión por número de licencia, aunque un cambio de nombre del animal modifique `license_id`.

## Ingesta y pruebas

Los scripts externos de ingesta de delitos y arrestos no están incluidos en este checkout. Según la documentación previa, detectan cambios en Seattle Open Data, comparan filas y multiplicidades con un histórico SQLite y suben lotes a Snowflake sin propagar bajas ni automatizar licencias o cartografía. No se ha verificado que la programación de `systemd` ni la task de carga estén activas. [El contexto](contexto.md#ingesta-y-datos-locales) conserva las precauciones para retomar ese trabajo. `Datos_ejemplo/` está ignorada por Git y no es una fuente dbt.

- **Revisiones anteriores.** El 19 de noviembre de 2026 se comprobó mediante consultas de solo lectura que staging conservaba los recuentos de RAW. En licencias, 38.413 filas daban 38.410 números distintos: las tres repeticiones eran duplicados exactos de negocio, lo que respaldaba el uso de `DISTINCT` para aquella carga. El [registro de la primera versión de `MERGE`](docs/arrest_incremental.md#validación-de-la-implementación-inicial-del-merge) recoge también una regresión nativa en un entorno aislado. Ninguna de esas comprobaciones valida la versión actual.
- **Versión actual.** Falta el `dbt build` integral en Snowflake. La [regresión de integración](tests/integration/arrest_delete_insert_check.py) usa datos sintéticos y un esquema DEV aislado.

## Ejecución en desarrollo

Configurar `DBT_BRONZE` y `DBT_SILVER` para DEV (`DEV_BRONZE` y `DEV_SILVER` en el entorno documentado). Son variables obligatorias y no se cambian con `--target`. En dbt Core, usar el perfil `default` configurado fuera del repositorio; en Studio, usar las variables del entorno de desarrollo. El rol necesita acceso al warehouse, lectura de RAW y permisos de escritura en los destinos de desarrollo. [`packages.yml`](packages.yml) fija `dbt_utils` 1.4.1.

```bash
dbt deps
dbt parse
```

Validar primero en un destino aislado. El comando de construcción y los requisitos de cartografía están en la [guía de Silver](docs/silver.md#ejecución-en-dev).

Si Silver ya tiene un esquema anterior, revisar antes qué tablas y referencias deben reconstruirse juntas. `on_schema_change='fail'` no migra columnas y las claves de `agents` y `subject` ahora dependen solo del identificador. Comprobar el histórico de RAW, respaldar los destinos y acordar la migración antes de ejecutar `--full-refresh`. Los datos que solo existan en Silver no se recuperan desde RAW. El [contexto operativo](contexto.md#por-dónde-retomar) detalla qué queda por comprobar antes del primer despliegue.
