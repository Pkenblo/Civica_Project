# Civica Project

Cívica prepara datos abiertos de Seattle con dbt y Snowflake: delitos, detenciones, licencias de mascotas y cartografía postal. El código postal (CP) permite comparar estos conjuntos por zona. **La relación es geográfica:** compartir CP no vincula una mascota, una persona o una licencia con un hecho policial.

Esta memoria recoge las decisiones del proyecto y por qué se tomaron. El [diccionario y DBML](docs/silver_diagram.md) y el [diagrama Silver](docs/silver_diagram.svg) muestran las columnas y relaciones. [Detenciones en Silver](docs/arrests.md) explica el `MERGE` con un ejemplo. Para retomar el desarrollo, consultar [contexto.md](contexto.md).

## Capas y alcance

| Capa | Dónde | Qué hace |
| --- | --- | --- |
| Bronze | `DBT_BRONZE.RAW` | Declara `CRIMES`, `ARRESTS`, `PET_LICENSES` y `ZIPCODE_AREAS`. La carga es externa a dbt. |
| Staging | `DBT_BRONZE.STG` | Cuatro vistas que renombran columnas, convierten tipos y normalizan valores sin resolver duplicados ni eliminar asociaciones. |
| Silver | `DBT_SILVER.SILVER` | 19 modelos: 11 tablas incrementales, 7 tablas reconstruidas en cada ejecución y 1 vista de auditoría. |
| Gold | Sin implementar | Todavía no hay modelos Gold ni snapshots en uso. |

Staging pasa a mayúsculas los textos descriptivos y los códigos, recorta espacios y convierte vacíos y marcadores conocidos en `NULL`. `arrest_type` también unifica espacios internos. Los identificadores y los metadatos de procedencia conservan su escritura. Limpiar aquí, y no en cada modelo Silver, mantiene una sola regla para todos los consumidores. Se conserva `_INGESTED_AT` como `ingested_at`, además del lote y el fichero. Latitud y longitud se publican como `NUMBER(18,5)`; staging evalúa los marcadores y rangos antes de redondear. No se redondean fechas, identificadores ni geometrías postales.

## Delitos: conservar el detalle sin inflar los recuentos

En el CSV inicial se observaron 1.575.312 filas y 1.575.310 `offense_id` distintos. Las repeticiones observadas correspondían a tipos de tiroteo distintos. `crime_shooting_types` extrae las asociaciones antes de deduplicar `crimes`, para que un delito pueda tener varios tipos sin repetir el hecho por ese motivo. `crimes` elimina duplicados completos, pero **no garantiza aún una fila por `offense_id`**: si dos versiones tienen atributos de negocio distintos, no elige una de forma arbitraria.

`offense_categories` tiene una fila por categoría y `offense_subcategories` una por combinación de categoría y etiqueta. Conservar la categoría en la clave de subcategoría evita mezclar etiquetas iguales si aparecen bajo categorías distintas. El CSV de ejemplo tenía tres categorías y 31 subcategorías, cada una con un solo padre. `crimes` guarda las dos referencias: así conserva una categoría informada aunque falte la subcategoría. Tampoco se inventa una categoría padre cuando llega solo la subcategoría.

**NIBRS se mantiene separado.** Describe un código y su clasificación (por ejemplo, `PERSON`, `PROPERTY` o `SOCIETY`), no las agrupaciones `VIOLENT CRIME`, `PROPERTY CRIME` y `ALL OTHER` del dataset. Los 64 códigos informados de la muestra se asociaban cada uno a una categoría y subcategoría, pero había 1.643 filas con categoría y sin código NIBRS. Pasar obligatoriamente por `nibrs` perdería esa información. El catálogo conserva variantes contradictorias de un código para que las pruebas de unicidad las señalen.

## Detenciones: una fila por arresto, varias infracciones si existen

`arrest` usa `arrest_number` directamente como clave del `MERGE`. No utiliza `report_id`: un informe puede tener varias detenciones. El modelo `arrest_offenses` conserva una asociación por detención, tipo de infracción y descripción NIBRS observada. No une esa descripción textual a un código NIBRS por suposición. En el CSV inicial había 145.625 filas para 110.143 detenciones; las filas repetidas no eran necesariamente duplicados que debían borrarse.

El `MERGE` se alimenta de una comparación del historial de RAW por detención, no de los nombres de fichero ni de la fecha del arresto. Silver guarda `last_ingested_at`, `source_version_count` y `source_signature`. La firma permite detectar una versión distinta con el mismo instante de ingesta o con una fecha anterior al máximo ya procesado. Solo se consolida de nuevo el historial de los IDs afectados, aunque se siga leyendo staging para detectar cambios. RAW debe conservar sus versiones; la firma identifica el contenido de origen, no la versión del código dbt.

Por columna gana el valor no nulo más reciente según `ingested_at`; un hash desempata si coincide el instante. Por ejemplo, `(x, NULL, y)` y una versión posterior `(NULL, z, r)` producen `(x, z, r)`. La completitud sigue disponible como métrica, pero un registro antiguo no gana por tener más campos rellenos. Se descartaron microbatch y el cursor por lote: una detención antigua puede cambiar con una ingesta nueva y un lote no equivale a un único instante de carga.

- **Agentes y sujetos.** Se elige el último identificador no nulo y solo se toman atributos compatibles con esa identidad. Si `A2` sustituye a `A1`, un atributo que no conste para `A2` no se copia de `A1`. Tampoco se inventa un sujeto cuando falta su ID. `agents` y `subject` catalogan combinaciones observadas, no vigencias temporales. La edad del agente (`agents_age_at_detention`) y el rango de edad del sujeto (`subgect_age_at_detention`, nombre actual de la columna) se guardan en la detención: pueden cambiar entre eventos sin cambiar la identidad del catálogo.
- **Ubicaciones.** Una versión `REDACTED` no aporta ubicación y no borra una ubicación que otra versión sí publicó. Si la última versión está marcada y no hay atributos de ubicación disponibles, se conserva el estado `redacted`. No se deduce ninguna dirección nueva.
- **Despacho CAD.** `cad_profiles` reúne cierre, tipo inicial y prioridad. `arrest` publica `cad_profile_id`, que queda nulo si faltan los tres campos. Dos detenciones pueden compartir perfil sin corresponder a la misma llamada: la fuente no trae un ID de llamada CAD. El catálogo se alimenta de los valores consolidados de `arrest`.
- **Auditoría.** `arrest_conflicts` muestra los valores candidatos y el elegido por campo. `consolidation_choices` conserva los atributos consolidados antes de generar las referencias y permite respaldar valores ya publicados cuando RAW no aporta uno. El respaldo no debe trasladar atributos de una persona a otra.

## Catálogos incrementales

Además del `MERGE` de `arrest`, diez modelos usan `delete+insert`: `cad_profiles`, `police_add`, `agents`, `subject`, `arrest_types`, `offense_types`, `nibrs`, `offense_categories`, `offense_subcategories` y `shooting_types`.

Se eligió `delete+insert` en lugar de `append` para poder reemplazar las filas de una clave cuando cambian sus atributos sin que cambie la clave. Un `append` dejaría la fila antigua junto a la nueva aunque la antigua ya no estuviera en el origen. La [macro común](macros/utils/changed_catalog_rows.sql) devuelve todos los candidatos en la primera carga y, en modo incremental, compara filas completas contra el destino para encontrar las claves con alguna fila nueva o distinta. dbt reemplaza **todas las filas de esas claves**, no solo la variante nueva. Así, si en origen siguen constando dos descripciones contradictorias para un código NIBRS, el modelo conserva las dos y la prueba de unicidad señala el conflicto.

Si no hay filas nuevas ni distintas en origen, no se reescribe nada. La comparación no detecta bajas por sí sola: ni una clave que desaparece por completo ni una variante eliminada si el resto de sus filas no cambia. El ahorro está en las escrituras; la consulta sigue leyendo el origen para buscar diferencias.

## Informes, áreas policiales y código postal

`reports` reúne números de informe de ambos dominios. En arrestos se transforma únicamente el formato aprobado `YYYY0000NNNNNN` a `YYYY-NNNNNN`; el original permanece en RAW. La fecha y hora del informe procede de delitos: no se rellena con la fecha del arresto. Compartir informe no prueba qué arresto corresponde a qué delito; unir los dos hechos por `report_id` puede multiplicar las filas. `police_add` usa la combinación de distrito, sector y beat, porque un beat no se presupone único. Se conservan las áreas parciales.

La cartografía de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area) se exportó a EPSG:4326; la capa nativa usa EPSG:2926. La descarga de referencia tenía 273 entidades y 251 CP distintos. `postal_codes` valida un solo mapa activo, une las piezas de cada CP y admite códigos de licencias sin polígono local. Antes de materializar `full_address`, hay que confirmar de forma independiente que las coordenadas **policiales** están en EPSG:4326; la proyección del mapa no demuestra la del origen policial.

`full_address` calcula el CP solo si exactamente una zona cubre el punto y este cae en su interior (`ST_COVERS` y `ST_CONTAINS`, con longitud antes de latitud). Guarda `cp_status`: `matched`, `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous` o `boundary`. Si no hay coincidencia interior única, `cp` queda nulo. No se aproxima al CP más cercano ni se necesita una tabla de asignaciones. La clave de dirección no depende del CP, de su estado ni de la versión del mapa.

`licencia` excluye las filas sin número de licencia y toma el CP de origen si consta de cinco dígitos; no lo completa ni elimina una licencia por falta de CP. `license_id` es el hash de `license_number` y `animal_name`, no de la fecha, la especie, las razas ni el CP. Se eliminan duplicados exactos de negocio y se comprueba el grano por número de licencia. Si aparecen variantes, se conservan para revisión: un hash distinto no equivale a un snapshot ni a un historial de vigencias.

## Ingesta y pruebas

Los scripts externos de ingesta de delitos y arrestos no están incluidos en este checkout. Según la documentación previa, detectan cambios en Seattle Open Data, comparan filas y multiplicidades con un histórico SQLite y suben lotes a Snowflake sin propagar bajas ni automatizar licencias o cartografía. No se ha verificado que la programación de `systemd` ni la task de carga estén activas. [El contexto](contexto.md#ingesta-y-datos-locales) conserva las precauciones para retomar ese trabajo. `Datos_ejemplo/` está ignorada por Git y no es una fuente dbt.

- **Revisiones anteriores.** El 19 de noviembre de 2026 se comprobó mediante consultas de solo lectura que staging conservaba los recuentos de RAW. En licencias, 38.413 filas daban 38.410 números distintos: las tres repeticiones eran duplicados exactos de negocio, lo que respaldaba el uso de `DISTINCT` para aquella carga. El [registro de la primera versión de `MERGE`](docs/arrest_incremental.md#validación-de-la-implementación-inicial-del-merge) recoge también una regresión nativa en un entorno aislado. Ninguna de esas comprobaciones valida la versión actual.
- **Versión actual.** El último `dbt parse` registró 98 pruebas de datos y 24 pruebas unitarias. Se compilaron los modelos afectados y se probaron casos sintéticos en DuckDB, incluidos cambios de identidad, ingestas tardías, relaciones de categorías, perfiles CAD y reemplazo de catálogos sin reescrituras en una repetición. Los recuentos de pruebas declaradas no equivalen a pruebas ejecutadas. No consta un `dbt build` integral satisfactorio de esta versión en Snowflake.
- **Pendiente conocido.** `arrest` admite versiones sin `officer_id`, pero el test `not_null` de `stg_arrests.officer_id` aún las señala. Es una discrepancia por resolver antes de considerar cerrado el flujo. No se reintroducen los tests masivos `normalized_text`; la limpieza sigue cubierta con pruebas específicas.

## Ejecución en desarrollo

Configurar `DBT_BRONZE` y `DBT_SILVER` para DEV (`DEV_BRONZE` y `DEV_SILVER` en el entorno documentado). Son variables obligatorias y no se cambian con `--target`. En dbt Core, usar el perfil `default` configurado fuera del repositorio; en Studio, usar las variables del entorno de desarrollo. El rol necesita acceso al warehouse, lectura de RAW y permisos de escritura en los destinos de desarrollo. [`packages.yml`](packages.yml) fija `dbt_utils` 1.4.1.

```bash
dbt deps
dbt parse
```

Validar primero en un destino aislado. Una vez confirmado el CRS policial y resuelta la discrepancia de `officer_id`, ejecutar el flujo completo con `dbt build --select path:models/staging path:models/silver`. El build debe incluir los dependientes que se quieran actualizar, como `cad_profiles` después de `arrest`; ejecutar solo `arrest` no los reconstruye.

Si Silver ya tiene un esquema anterior, revisar antes qué tablas y referencias deben reconstruirse juntas. `on_schema_change='fail'` no migra columnas y las claves de `agents` y `subject` cambiaron al sacar las edades. Comprobar el histórico de RAW, respaldar los destinos y acordar la migración antes de ejecutar `--full-refresh`. Los datos que solo existan en Silver no se recuperan desde RAW. El [contexto operativo](contexto.md#por-dónde-retomar) detalla qué queda por comprobar antes del primer despliegue.
