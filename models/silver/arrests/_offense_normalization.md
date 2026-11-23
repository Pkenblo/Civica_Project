{% docs offense_normalization %}

## Normalización legal y catálogo NIBRS compartido

### Grano, claves y relaciones

```text
Silver:  nibrs (nibrs_key) ───< crimes (sin cambios)
                    └────────< arrest_offenses >──── offense_types
                                      │              (offense_type_id)
                                      ▼
                                arrest (sin cambios)

Gold:    dim_nibrs ───────────< fact_crimes (sin cambios)
              └──────────────< bridge_arrest_offenses >──── dim_offense_types
                                      │
                                      ▼
                               fact_arrests (sin cambios)
```

- `offense_types`: un texto completo no nulo de `stg_arrests.offense_type`. PK generada con `dbt_utils.generate_surrogate_key(['offense_type'])`. No se deduplica por código ni por los cuatro componentes; textos legales distintos conservan identidades distintas. Todas las variantes exactas de RAW se guardan en el array ordenado `offense_type_original_values`.
- `arrest_offenses`: una combinación histórica observada `(arrest_number, offense_type, nibrs_description)` de staging para una detención publicada. La PK usa `dbt_utils.generate_surrogate_key` sobre esos tres campos, en ese orden. No se recalcula desde las nuevas FKs. Las FKs independientes son `offense_type_id` y `nibrs_key`; `arrest_number` sigue referenciando `arrest`.
- `nibrs`: una fila por código publicado, PK generada con `dbt_utils.generate_surrogate_key(['offense_code'])`. Conserva el código, descripción, grupo A/B y categoría contra la que se dirige el delito. Se mantiene la resolución por código de `crimes`.
- `dim_offense_types`: mismo grano, clave y atributos que el catálogo Silver. `dim_nibrs` sigue siendo la única dimensión NIBRS.
- `bridge_arrest_offenses`: mismo grano e ID que `arrest_offenses`, con las dos nuevas FKs, estado NIBRS y texto excepcional. Continúa siendo **ephemeral**, no una nueva tabla Gold. Sus relaciones se validan contra `fact_arrests`, `dim_offense_types` y `dim_nibrs`.
- Staging conserva todas las filas y añade `offense_type_original`, `nibrs_description_original`, `nibrs_offense_code_original` y `nibrs_offense_code_description_original`, sin limpiar los originales. Las columnas normalizadas conservan sus reglas anteriores; no cambian las claves existentes por nuevas limpiezas de espacios.

Compartir NIBRS permite comparar clasificaciones, no identificar una relación individual entre un delito y una detención. Para contar detenciones, usar `EXISTS` sobre el puente o agregar por `arrest_number` antes de unirlo al hecho.

### Separación conservadora y excepciones

La extracción sintáctica y la clasificación semántica se resuelven por separado. Una descripción sin categoría explícita puede estar correctamente parseada. El parser reconoce:

- Fuentes RCW/SMC con o sin guion, y guiones duplicados entre fuente y código.
- Códigos con puntos y subsecciones equilibradas; las letras separadas antes de `|`, como `12A.10.130 A`, se conservan literalmente, sin convertirlas en `(A)`.
- Identificadores externos numéricos. En `2299 | 9A.56.063 | ...`, `external_code = 2299`, `legal_code = 9A.56.063` y `legal_source = NULL`: no se infiere RCW desde el código.
- Dos referencias encadenadas. Las columnas `secondary_legal_source` y `secondary_legal_code` conservan la segunda normativa, incluso si falta la barra entre su código y la descripción.
- Descripciones sin barra, después de un código delimitado por espacios. El literal `I` de los dos textos `RCW ... I HARASSMENT ...` permanece en la descripción; no se sustituye por una barra ni se borra por suposición.
- Varios segmentos descriptivos. `offense_description` conserva el sufijo **completo**, con barras, guiones y segmentos anidados. Los calificadores `(PROP DAMAGE)`, `(INTERFERE)` y `(OF A MINOR)` permanecen en ese sufijo, no se incorporan al código legal.
- Las tres etiquetas administrativas observadas, sin asignarles códigos legales.

La gramática de códigos es conservadora: componentes numéricos de hasta cuatro cifras, sufijos alfanuméricos y paréntesis equilibrados. No valida la vigencia jurídica. Los códigos concatenados, caracteres `©` y paréntesis incompletos quedan para revisión, sin truncarlos para obtener un código aparentemente válido.

| Estado | Componentes publicados | Revisión |
| --- | --- | --- |
| `parsed` | Referencias y descripción extraídas, o identificador externo con descripción. La categoría puede ser nula. | No |
| `administrative` | Texto administrativo íntegro; fuentes y códigos legales nulos. | No |
| `review_required` | Solo los componentes seguros, por ejemplo la fuente explícita y la descripción; un código inseguro queda nulo. | Sí |

No hay estado `partial` por el mero hecho de faltar categoría. `needs_review` se conserva por compatibilidad y solo es verdadero para `review_required`.

**Conservación del original:** el parser no filtra filas por su estado ni sustituye `offense_type` o su clave por NULL. El texto completo normalizado sigue en `offense_type`; el array existente `offense_type_original_values` conserva todas las variantes exactas. No se añade otra columna original redundante. Los marcadores RAW que staging ya normalizaba a NULL no forman parte de los 728 textos del catálogo; no se cambia esa regla ni ningún modelo de staging en esta revisión.

### Categorías explícitas, no un separador universal

Tras revisar los 728 textos se admiten cuatro familias publicadas literalmente: `ASSAULT`, `DRUGS`, `FIRE` y `KIDNAP/IMPRISON`. No se asignan desde un código, NIBRS ni palabras sueltas de una descripción. Se extrae la familia antes de ` - ` y se conserva **todo** el resto en `offense_detail`, incluidos los guiones siguientes. También se reconoce el literal `DRUGS | ...`; sus segmentos restantes permanecen juntos, sin inventar campos de sustancia o modalidad. `DRUGS -| HEROIN - POSSESSION` se conserva completo sin categoría, porque ese límite es irregular.

Los 176 sufijos que contienen ` - ` después de la primera barra no son 176 jerarquías: algunos contienen la segunda referencia `RCW - código`. Después de extraer las referencias quedan 165 descripciones con ese separador y 61 prefijos literales distintos. No se considera que todos sean familias. Por ejemplo, `DRIVER LICENSE SUSPENDED/REVOKED - SECOND DEGREE`, `SPECIAL ALLEGATION - SEXUAL MOTIVATION` y las descripciones de DUI permanecen completas, sin asignación semántica automática.

Se obtienen 54 categorías explícitas: `ASSAULT` 17, `DRUGS` 30, `FIRE` 4 y `KIDNAP/IMPRISON` 3. Las otras 674 filas conservan categoría y detalle nulos. No se ha creado un catálogo de equivalencias inferidas ni se ha intentado completar categorías ausentes. Para ampliar estas familias hace falta una revisión explícita de las correspondencias, no otra heurística.

NIBRS se resuelve **solo** por igualdad exacta de la descripción normalizada de staging con `nibrs.offense_description`. La agrupación previa garantiza como máximo una fila de JOIN por descripción. Con una coincidencia se publica la FK; sin coincidencia o con varias, el cargo conserva `unresolved_nibrs_description` y estado `unmatched` o `ambiguous`, con FK nula. El estado `missing` representa una ausencia de origen. Las excepciones no descartan cargos, pero hacen fallar `arrest_nibrs_correspondence` para impedir una publicación inadvertida.

### Incrementalidad

`offense_types` usa `delete+insert`, `unique_key='offense_type_id'` y `on_schema_change='fail'`. La CTE `candidates` aplica `after_max_ingested_at` al leer staging: solo entran filas con `ingested_at > MAX(ingested_at)` del destino, igual que en los demás incrementales con cursor. Elige la última observación elegible por texto, con desempates por fichero, lote y texto original, y publica su `ingested_at`. Para los tipos del lote recupera también las variantes originales históricas, sin recalcular los demás tipos. Las claves nuevas con ingesta igual o anterior al máximo se omiten; un destino vacío requiere `--full-refresh`. La tabla existente debe reconstruirse una vez para añadir el cursor, tras verificar el histórico de RAW y respaldar el destino.

`arrest_offenses` usa `delete+insert`, `unique_key='arrest_offense_id'` y `on_schema_change='fail'`. En `observations`, la macro `after_max_ingested_at` filtra staging por `ingested_at > MAX(ingested_at)` del destino. Cada combinación conserva la mayor ingesta del lote elegible; solo se reemplazan los cargos recibidos y no se eliminan otros por omisión. Las ingestas iguales o anteriores al máximo se omiten. Un cambio del catálogo NIBRS no recalcula cargos fuera del lote: para ello hace falta `--full-refresh`. La tabla existente debe reconstruirse una vez para añadir `ingested_at`, tras verificar el histórico de RAW y respaldar el destino. No cambian `arrest`, `crimes`, `fact_arrests` ni `fact_crimes`.

### Validación disponible

Los resultados de esta sección corresponden a la revisión del parser anterior a la unificación de claves con `dbt_utils.generate_surrogate_key`. La migración posterior cambia las claves compuestas, incluido `arrest_offense_id`: las afirmaciones históricas de identidad y compatibilidad no se aplican a ese cambio. Es necesario reconstruir Silver y sus dependencias Gold con `--full-refresh`, tras verificar el histórico de RAW y los respaldos; una ejecución incremental no migra las referencias existentes.

Esta revisión usa **todos los registros** de `/home/pablo/Downloads/pruebas_sobre_silver_2026-11-22-2120.csv`: 728 filas, 728 textos distintos. SHA-256: `2153796dec6ee35abb5b1d7e33eb9b57a4713cf996acd4ef02a45f2b9b41bd0a`. Hay 691 textos con una barra, 28 con varias y 9 sin ninguna. Se verificaron también los prefijos: 409 RCW con guion, 3 RCW sin guion, 303 SMC con guion, 1 SMC sin guion, 9 identificadores externos y 3 etiquetas administrativas.

El conjunto de textos coincide exactamente con el de la captura pública conservada de la revisión anterior. Esa captura permite volver a comprobar cargos y detenciones en memoria; el CSV de 728 valores no contiene identificadores de eventos ni frecuencias de cargos. No se ha ejecutado DDL/DML ni validado el despliegue Snowflake. NIBRS no se ha modificado en esta revisión.

El CSV local `datos_ejemplo/Todos_los_crimenes.csv` tiene 64 códigos y 64 descripciones únicas, coincidentes con los 64 pares no nulos publicados por delitos. El catálogo incluye `999 / NOT REPORTABLE TO NIBRS` y `500 / VIOLATION OF NO CONTACT ORDERS`: se respetan los códigos del origen, sin afirmar que todo el catálogo sea la lista oficial FBI vigente ni sustituir clasificaciones locales o históricas.

La regresión local ejecutó el SQL de los modelos mediante transpilación Snowflake → DuckDB; no es una ejecución nativa de dbt/Snowflake. Los hechos de detenciones se representaron como el conjunto de IDs de la captura, no como los hechos desplegados. Se obtuvieron:

| Comprobación | Resultado local |
| --- | --- |
| Filas del origen de detenciones | 145.873 |
| Detenciones antes / después | 110.323 / 110.323 |
| Cargos antes / después | 145.802 / 145.802 |
| Textos legales distintos no nulos antes / después | 728 / 728 |
| Sintaxis interpretada correctamente | 720 |
| Referencia legal recuperada sin categoría explícita, subconjunto de las anteriores | 664 |
| Identificador externo sin referencia legal en el original, también dentro de las 720 | 2 |
| Administrativos | 3 |
| Referencias realmente inseguras | 5 |
| Códigos legales principales / secundarios | 718 / 16 |
| Identificadores externos | 9 |
| Textos representados y variantes originales conservadas | 728; cobertura completa |
| Descripciones NIBRS no nulas en detenciones | 57 |
| Correspondencias únicas / sin correspondencia / ambiguas | 57 / 0 / 0 |
| Filas originales con NIBRS ausente (`-`) | 121 |
| Cargos con NIBRS ausente | 50 |
| Filas sin tipo legal ni NIBRS, sin cargo por el grano previo | 71 |
| Cargos resueltos a NIBRS | 145.752 |
| Códigos en el catálogo compartido | 64 |
| IDs de cargo cambiados, duplicados por JOIN, huérfanos y pérdidas | 0 |
| Regresiones unitarias / pruebas singulares locales sobre la captura de eventos | 4 / 8, todas correctas |

La comparación con el parser anterior, ejecutada sobre los mismos 728 textos, da:

| Interpretación | Anterior | Actual |
| --- | ---: | ---: |
| `parsed` | 114, exigía cuatro componentes | 720, mide sintaxis y no exige categoría |
| `partial` | 510 | Eliminado: ausencia de categoría no es error |
| Administrativos reconocidos | 0 | 3 |
| `review_required` | 104 | 5 |
| Categorías publicadas | 114, cualquier guion único | 54, solo cuatro familias explícitas revisadas |
| Textos originales representados | 728 | 728 |

Los cinco textos pendientes conservan fuente explícita, descripción y original; `legal_code` permanece nulo:

1. `SMC - 11.56.32011.56.320(C) | RIVER LICENSE SUSPENDED/REVOKED - SECOND DEGREE`
2. `SMC - 12A.06.010(A | ASSAULT`
3. `SMC - 12A.14.080© | POSSESS FIREARM-PUBLIC PROPERTY`
4. `RCW - 10.7RCW - 9.040.1 |  SEARCH WITHOUT LAWFUL WARRANT`
5. `SMC - 12A.06.040© | HARASSMENT NO CONTACT ORDER VIOL`

El reparto por detención se mantuvo íntegro: 0 cargos → 71 detenciones; 1 → 84.856; 2 → 18.277; 3 → 5.029; 4 → 1.480; 5 → 383; 6 → 163; 7 → 37; 8 → 15; 9 → 8; 10 → 3; 11 → 1. La comprobación compara cada ID y cada recuento por detención, no solo los totales.

Se ejecutaron `dbt parse` y `dbt compile` para modelos y pruebas de datos afectados con un perfil ficticio, `--no-introspect --no-populate-cache` y exclusión de tests unitarios en la compilación. Ambos terminaron correctamente. Persiste un aviso previo sobre `models.my_new_project.marts`, fuera de esta modificación. Los tests unitarios nativos y las pruebas sobre tablas reales quedan pendientes de conexión.

La comparación **por cada uno de los 728 textos** está en `/tmp/opencode/offense-parser-v2/offense_types_comparison.csv`; `category_prefix_review.csv` contiene todos los prefijos descriptivos observados y `real_csv_validation.json` los recuentos y la huella del CSV. Las verificaciones confirman cero originales ausentes, cero textos del catálogo nulos, cero claves inestables, cero códigos inventados y cero descripciones truncadas. La prueba `offense_type_references_resolved` comprueba además que cada cargo conserve la FK del texto que realmente le corresponde, no solo una FK existente.

Los resultados sobre eventos y las frecuencias de la captura siguen en `/tmp/opencode/seattle-normalization/`. Son artefactos temporales, no seeds ni fuentes dbt. Para repetir la comprobación con el CSV real y, opcionalmente, con esa captura, instalar `duckdb`, `sqlglot`, `jinja2` y `PyYAML` en un entorno de prueba y ejecutar:

```bash
python tests/integration/offense_normalization_local_check.py \
  --offense-types-csv /home/pablo/Downloads/pruebas_sobre_silver_2026-11-22-2120.csv \
  --output-dir /tmp/opencode/offense-parser-v2 \
  --snapshot-dir /tmp/opencode/seattle-normalization
```

Los tests dbt no fijan el tamaño del catálogo: siguen comprobando cobertura e integridad si llegan textos nuevos. El test unitario de un texto desconocido confirma que los originales no interpretables tampoco desaparecen.

### Despliegue acotado y compatibilidad

**No desplegar esta revisión sin autorización.** El esquema descriptivo de `offense_types` y `dim_offense_types` añade referencias secundarias, código externo y descripción completa; `offense_name` se sustituye por `offense_description` y `offense_detail`. Las claves y relaciones no cambian. `on_schema_change='fail'` impide migrar silenciosamente una tabla incremental ya existente. Cualquier migración física requiere revisar consumidores y respaldos; no se ha ejecutado ni se prescribe aquí una reconstrucción.

La validación dbt de esta revisión se limita a parsear y compilar, con el perfil ficticio externo ya preparado en esta sesión, sin consultar ni escribir en Snowflake:

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt parse --profiles-dir /tmp/opencode/seattle-normalization/profiles
dbt compile --profiles-dir /tmp/opencode/seattle-normalization/profiles \
  --no-introspect --no-populate-cache --indirect-selection cautious \
  --select offense_types dim_offense_types offense_types_coverage \
  offense_types_parse_contract offense_type_references_resolved \
  arrest_offenses_preserved arrest_offense_counts_preserved offense_type_originals_preserved \
  --exclude resource_type:unit_test
```

Los tests nativos sobre tablas Snowflake y la migración del esquema quedan pendientes. La igualdad Silver/Gold conserva todas las claves y compara los nuevos atributos; la regresión local comprueba la repetición del parser sin cambios de identidad. No se cambia el SQL de `arrest_offenses`, los puentes, los hechos, staging ni NIBRS en esta revisión.

Ningún datamart actual referencia `bridge_arrest_offenses` ni sus columnas retiradas; `mart_arrest_socioeconomic` consume `fact_arrests`, que no cambia. Los marts de delitos siguen usando `dim_nibrs` sin cambios. **No se han modificado datamarts.** Las consultas externas que lean `arrest_offenses.offense_type` o `.nibrs_description` deben usar ahora `offense_types`/`dim_offense_types` y `nibrs`/`dim_nibrs`; conservar el texto excepcional mediante `coalesce(unresolved_nibrs_description, offense_description)` cuando proceda. No se han migrado consumidores externos ni reescrito los diagramas generales históricos fuera de este alcance.

{% enddocs %}
