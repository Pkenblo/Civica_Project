# Detenciones en Silver (versión anterior)

La implementación vigente se documenta en [Silver de Seattle](silver.md). El texto siguiente se conserva como antecedente de la migración.

`arrest` usa `delete+insert` por `arrest_number`. Si llega una versión más reciente del mismo ID, dbt borra la fila anterior e inserta la nueva entera. Si un campo llega nulo, queda nulo: no se rellena con datos de otras versiones. Una ubicación marcada `REDACTED` tampoco hereda la ubicación anterior.

`stg_arrests` conserva todas las filas y normaliza los datos. `arrest` elige una fila por `ingested_at`; si hay empate, usa el fichero de origen y un desempate estable por contenido. Conserva `last_ingested_at` para trazabilidad, no como cursor. Una alta con una fecha anterior a la de otros arrestos entra; una versión anterior a la ya publicada para su ID no la sustituye.

Los modelos comparan sus filas candidatas con las publicadas. Solo las claves nuevas o con datos distintos se escriben; si no hay cambios no se reescribe nada. Esto no propaga borrados del origen y sigue leyendo staging para buscar diferencias.

| Modelo | Clave de reemplazo |
| --- | --- |
| `arrest` | `arrest_number` |
| `agents` | `officer_id` |
| `subject` | `sk_person` |
| `arrest_offenses` | `arrest_offense_id`, una asociación por detención, tipo y descripción NIBRS |
| `arrest_types`, `cad_profiles` | `arrest_type_id`, `cad_profile_id` |
| `reports`, `police_add`, `full_address` | `report_id`, `police_area_id`, `address_id` |

`agent_key` y `subject_key` se derivan solo de sus identificadores de origen. Cambiar atributos de una persona no cambia su clave; si la última fila del arresto no identifica al agente o al sujeto, la referencia queda nula. Las edades siguen en la detención. `arrest_offenses` conserva cargos distintos del mismo arresto; si cambia la asignación NIBRS de un cargo, se reescribe esa asociación sin borrar las demás. `cad_profiles` se construye después de `arrest` y no identifica llamadas individuales.

## Migración y prueba

Si ya hay tablas Silver con el esquema o las claves anteriores, comprobar que RAW conserva los datos, respaldar los destinos y coordinar una reconstrucción de `arrest`, `agents`, `subject` y sus catálogos antes de activar el incremental. No es necesario reconstruir RAW. `full_address` asume EPSG:4326 para las coordenadas policiales. La regresión de [integración](../tests/integration/arrest_delete_insert_check.py) usa un esquema Snowflake aislado y datos sintéticos; no valida el CRS real.
