# Detenciones en Silver

[`arrest`](../models/silver/arrests/arrest.sql) publica **una fila por `arrest_number`**. Ese identificador de origen es la clave del `MERGE`: una detención nueva se inserta y una existente se actualiza. `report_id` referencia el informe asociado, que puede estar vinculado a varias detenciones.

## De RAW a `arrest`

[`stg_arrests`](../models/staging/stg_arrests.sql) normaliza los textos, convierte los tipos y redondea las coordenadas a cinco decimales antes de compararlas. Conserva las versiones de RAW y las filas asociadas a distintas infracciones.

En cada ejecución, `arrest` compara el inventario de versiones normalizadas de cada detención con el que guardó en Silver: `last_ingested_at`, `source_version_count` y `source_signature`. El inventario recorre staging, pero solo se vuelve a consolidar el historial de las detenciones nuevas o modificadas. La firma permite detectar versiones añadidas tarde o con la misma fecha de ingesta; no depende de `batch_id`, de la fecha de la detención ni del número de infracciones repetidas en un fichero. Si el histórico no cambia, el `MERGE` no tiene filas que procesar. Para que el recálculo funcione, RAW debe conservar las versiones anteriores.

## Cómo se elige cada valor

La [macro de consolidación](../macros/arrests/consolidate_arrests.sql) ordena las versiones por fecha de ingesta descendente. Para cada columna escoge el primer valor no nulo; si dos versiones tienen la misma fecha, desempata con un hash. La completitud se conserva como métrica, no como criterio de selección. Valores como `0` y `false` cuentan como datos, no como ausencias.

Por ejemplo, si la versión anterior contiene `(x, NULL, y)` y la nueva trae `(NULL, z, r)`, el resultado es `(x, z, r)`. Una versión con fecha de ingesta anterior que se incorpora tarde puede rellenar un hueco, pero no pisa un dato más reciente.

Si el historial no aporta un valor para un campo, el incremental puede conservar el que ya estaba publicado en Silver. Para atributos de agente o sujeto, ese respaldo no puede trasladar datos de una identidad a otra.

- **Agente y sujeto.** Se elige el último identificador no nulo de cada uno. Si el agente cambia de `A1` a `A2`, sus atributos se buscan solo entre versiones que identifiquen a `A2`; los que no consten para ese agente quedan nulos. Lo mismo se aplica al sujeto. La edad del agente (`agents_age_at_detention`) y el rango de edad del sujeto (`subgect_age_at_detention`) son datos de la detención y no forman parte de las claves de `agents` o `subject`.
- **Ubicación.** Una versión marcada `REDACTED` no aporta ubicación ni borra datos válidos de otras versiones. Si no hay ubicación disponible y la última versión está marcada, se conserva el estado `redacted`.

## Detalle, catálogos y auditoría

| Modelo | Qué representa |
| --- | --- |
| [`arrest_offenses`](../models/silver/arrests/arrest_offenses.sql) | Una asociación por detención, tipo de infracción y descripción NIBRS observada. Conserva las infracciones del histórico sin duplicar la fila principal. |
| [`cad_profiles`](../models/silver/arrests/cad_profiles.sql) | Una fila por combinación consolidada de cierre (`cad_clearance`), tipo de inicio (`cad_initial_call_type`) y código de prioridad (`cad_priority`). `arrest` se une por `cad_profile_id`. |
| [`arrest_conflicts`](../models/silver/arrests/arrest_conflicts.sql) | Una fila por detención y campo con valores contradictorios. Muestra los candidatos y el valor elegido. |

CAD (*Computer-Aided Dispatch*) es el sistema de despacho. Un perfil puede tener campos nulos, pero si faltan los tres, `cad_profile_id` queda nulo. Dos detenciones pueden compartir perfil sin proceder de la misma llamada: la fuente no proporciona un identificador de llamada CAD. El catálogo se construye después de `arrest` con los valores consolidados; estos siguen disponibles en `consolidation_choices` para auditoría y respaldo del incremental.

## Ejecución y comprobaciones pendientes

Para construir el bloque con sus dependencias, incluida la actualización del catálogo CAD después de `arrest`:

```bash
dbt build --select +cad_profiles +arrest_offenses arrest_conflicts
```

Antes de usar este comando en DEV, comprobar `DBT_BRONZE` y `DBT_SILVER` y confirmar el sistema de coordenadas que exige `full_address`. Si Silver ya tiene el esquema anterior, preparar una reconstrucción coordinada: `arrest` tiene `on_schema_change='fail'` y las claves de `agents` y `subject` cambiaron al sacar las edades.

Pasaron la compilación local de dbt y la regresión con datos sintéticos en DuckDB. Falta ejecutar la [integración nativa](../tests/integration/arrest_merge_check.py) en Snowflake y resolver una discrepancia: `arrest` admite versiones sin `officer_id`, pero el [test `not_null` de staging](../models/staging/_stg_models.yml#L279) las sigue marcando como error.
