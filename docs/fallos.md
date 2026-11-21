# Histórico: revisión del primer diseño Silver

Esta revisión describe los problemas del primer diseño, no el estado actual. Para las decisiones adoptadas y el único diagrama vigente, consultar la [memoria de Silver](silver.md) y la [referencia definitiva](silver_diagram.md).

Esta revisión identifica problemas y decisiones pendientes del diseño. No todos los puntos son errores confirmados: algunos requieren comprobar los datos. Se ha comprobado localmente la viabilidad del enriquecimiento postal con los CSV; no se han ejecutado cargas ni consultas de validación en Snowflake, ni modificado los modelos dbt.

## 1. Grano y selección de versiones sin definir

**Estado:** decisión pendiente; requiere validar los datos.

El diagrama propone las siguientes claves primarias:

| Tabla | Clave primaria | Grano propuesto |
| --- | --- | --- |
| `Crimes` | `offense_id` | Una fila por delito. |
| `Arrest` | `arrest_number` | Una fila por arresto. |
| `Licencia` | `license_number` | Una fila por licencia. |

La documentación de `models/staging/_stg_models.yml` indica que staging conserva versiones y filas asociadas a distintos tipos de tiroteo o infracciones. Para licencias, indica que conserva los registros sin deduplicar.

Los puentes `Crime_shooting_types` y `Arrest_offenses` permiten representar asociaciones múltiples, pero no definen qué hacer con las versiones de un mismo registro.

**Riesgo:** eliminar información válida al deduplicar, mezclar atributos de versiones distintas o generar varias filas para una PK que debería ser única.

**Qué resolver:**

- Separar duplicados exactos, versiones y asociaciones múltiples.
- Comprobar si, para un mismo arresto, cambian también el agente, el sujeto u otros atributos que el diagrama representa con una sola referencia.
- Definir si Silver conservará únicamente el estado más reciente o también el histórico, y cómo se elegirá una versión cuando corresponda.
- Verificar si un mismo `license_number` puede tener distintas expediciones o renovaciones. Es una posibilidad que debe comprobarse, no un hecho confirmado.
- Validar la unicidad de las claves después de aplicar las reglas acordadas.

## 2. Temporalidad de agentes y sujetos sin resolver

**Estado:** decisión de modelado pendiente.

`Agents` contiene atributos que pueden cambiar, como `officer_age`, `squad_description` y `officer_title`. `Subject` contiene `subject_age_range`, que también puede variar entre intervenciones.

El diagrama no indica si cada fila representa el estado actual de una persona, sus características en una intervención o una versión histórica.

**Riesgo:** que un arresto antiguo quede asociado a la edad, unidad o cargo más recientes, alterando el contexto histórico. También puede ocurrir que una misma persona se duplique sin una regla clara de identidad.

**Qué resolver:**

- Distinguir la identidad del agente o sujeto de los atributos observados durante una intervención.
- Elegir qué atributos deben conservarse en el evento, cuáles pertenecen a la entidad y cuáles necesitan versiones históricas.
- Definir cómo se generan `agent_key` y `subject_key`, y qué relación tienen con `officer_id` y `sk_person`.
- No asumir que `officer_id` o `sk_person` son únicos en las tablas propuestas sin comprobarlo.

No es obligatorio aplicar historización a todas las tablas; la solución depende del significado de los atributos y de los análisis previstos.

## 3. Código postal de las ubicaciones policiales

**Estado:** solución incorporada al diseño; implementación y pruebas en Snowflake pendientes.

`Full_address` incluye `cp`, pero `models/staging/stg_crimes.sql` y `models/staging/stg_arrests.sql` no proporcionan un código postal. Las licencias sí lo incluyen como `zip_code` en `models/staging/stg_pet_licenses.sql`.

La [propuesta postal inicial](codigo_postal.md) planteaba resolver esta carencia mediante polígonos postales de King County y un cruce espacial. Proponía añadir `ref_zipcode_versions` y `ref_zipcode_areas`, además del estado, la versión, la fecha de evaluación y el número de CP candidatos en `Full_address`.

**Riesgo:** no poder construir la relación o asignar códigos postales incorrectos. Las direcciones policiales son aproximadas y algunas ubicaciones están ocultadas, por lo que no siempre será posible obtener un código fiable.

**Decisiones acordadas:**

- Obtener el CP de la zona que contiene el punto publicado, no de una tabla manual de calles.
- Conservar las instantáneas cartográficas y seleccionar una sola versión completa para cada evaluación.
- Mantener el CP nulo en ubicaciones ocultadas, sin coordenadas utilizables, sin coincidencia, con varios CP candidatos o exactamente en un límite postal.
- No limitar la referencia a Seattle ni imputar el CP más cercano.
- Confirmar los metadatos del sistema de referencia policial antes de activar el proceso y exportar los límites de King County a EPSG:4326.

La comprobación local encontró una única zona postal para el 74,41 % de las filas de delitos y el 98,34 % de las filas de arrestos. No son porcentajes de entidades únicas ni garantías de precisión postal. El procedimiento y sus límites se documentan en la [propuesta postal inicial](codigo_postal.md).

La comparación por código postal será una asociación geográfica; no vinculará una licencia concreta con un delito, arresto o persona.

## 4. Sujetos sin identificador frente a un campo obligatorio

**Estado:** diferencia confirmada entre staging y el diseño; tratamiento pendiente.

`models/staging/stg_arrests.sql` transforma `SK_PERSON` vacío o con el marcador `-1` en un `subject_id` nulo. En el diagrama, `Subject.sk_person` tiene una marca explícita de no nulidad.

Esto no obliga a que el diseño sea incorrecto: `Arrest.subject_key` podría quedar sin referencia cuando el sujeto no esté identificado. Sin embargo, esa política no está definida.

**Riesgo:** perder arrestos al exigir un sujeto identificado, generar claves artificiales sin significado o interpretar todos los registros desconocidos como si correspondieran a una misma persona.

**Qué resolver:**

- Definir si se permite `Arrest.subject_key` nulo o se utiliza un miembro técnico para representar información desconocida.
- Conservar los arrestos aunque falte el identificador del sujeto.
- Si se usa un miembro técnico, distinguirlo de una persona real y evitar contarlo como una identidad compartida.
- No generar una identidad personal a partir de edad, género o raza.

## 5. Trazabilidad y ocultación de ubicaciones no representadas

**Estado:** ausencia confirmada en el diagrama; falta decidir dónde conservar esta información.

Los tres modelos de staging incluyen `ingested_at`, `source_file` y `batch_id`. Los modelos policiales también incluyen `is_location_redacted`. Ninguno de estos campos aparece en el diagrama Silver.

No es necesario repetir todos los metadatos en todas las tablas, pero sí establecer cómo se podrá rastrear un registro Silver hasta sus entradas de origen.

**Riesgo:** dificultar la investigación de errores, no poder explicar qué registros alimentaron una entidad y perder la distinción entre una ubicación desconocida y una ocultada en la fuente.

**Qué resolver:**

- Conservar la trazabilidad necesaria en las tablas Silver o mediante relaciones de auditoría.
- Definir cómo se registra la procedencia cuando una fila Silver se construye a partir de varias filas de staging.
- Mantener la información de ocultación en el nivel que corresponda al registro de origen; no asumir que es una propiedad permanente de una dirección compartida.
- No tratar automáticamente una ubicación ocultada como una ubicación ausente por otros motivos.

## Estructuras que conviene mantener

- La separación entre `Crimes` y `Arrest`.
- `Reports` como referencia común, sin inventar una correspondencia directa entre cada delito y cada arresto.
- El puente `Crime_shooting_types` para los distintos tipos asociados a un delito.
- `Arrest_offenses` para conservar las distintas infracciones de un arresto.
- Las referencias geográficas compartidas, siempre que sus claves y reglas de identidad sean consistentes entre fuentes.

## Orden recomendado de revisión

1. Validar el grano de delitos y arrestos y separar versiones de asociaciones múltiples.
2. Resolver la temporalidad e identidad de agentes y sujetos.
3. Implementar y validar el enriquecimiento postal ya definido en el diseño.
4. Establecer el tratamiento de sujetos sin identificador.
5. Acordar la trazabilidad, la conservación de información ocultada y las pruebas de calidad antes de implementar Silver.
