# Encargo para OpenCode: incorporar datos socioeconómicos ACS 2024 hasta Silver

## 0. Objetivo y límites innegociables

**Implementar únicamente la integración del nuevo dataset de rentas del Census Bureau desde la tabla Bronze que ya está cargada, creando un modelo Staging y un modelo Silver.** Revisar previamente cómo están implementadas las demás tablas de cada capa y reproducir sus convenciones de nombres, fuentes, tipados, tests y materialización.

**No modificar ningún archivo, modelo, macro, seed, tabla, relación, configuración o test existente salvo que sea estrictamente imposible añadir los nuevos modelos sin un cambio y, en ese caso, DETENERSE, explicar el bloqueo y pedir autorización.** No hacer refactors, limpieza general, cambios de permisos, hooks, cambios de pipeline ni regenerar Gold.

**No crear ni modificar Gold, hechos, dimensiones ni datamarts.** No cambiar `postal_codes`, `full_address`, `crimes`, `arrests` ni ningún modelo ya existente. Toda relación adicional, si es técnicamente válida, deberá implementarse **solo dentro del nuevo modelo Silver**.

Antes de implementar: inspecciona el repositorio y los modelos actuales de `stg_*`, `licenses.sql`, `postal_codes.sql`, `full_address.sql` y el correspondiente `sources.yml` (los nombres/rutas reales pueden variar). No presupongas columnas o claves no comprobadas.

## 1. Fuente incorporada

- **Procedencia:** U.S. Census Bureau, American Community Survey (ACS), estimaciones **2020–2024** publicadas como ACS **2024 5-year**.
- **Ámbito geográfico:** todos los *census tracts* de **King County, Washington (FIPS `53` / `033`)**, no solamente Seattle.
- **Archivo inicial:** `rentas.json`, depositado en `@DEV_BRONZE.RAW.STG_SEATTLE_INITIAL_LOAD/rentas.json`.
- **Tabla Bronze creada/cargada mediante SQL:** `DEV_BRONZE.RAW.BRZ_CENSUS_SOCIOECONOMIC`.
- **Carga de arranque:** `BATCH_ID = 'INITIAL_LOAD'`.
- **Granularidad:** una fila por *census tract* (identificador geográfico `state || county || tract`).
- **Filas esperadas:** **495**; claves geográficas únicas: **495** en el archivo recibido.
- **Estructura del JSON original:** un array exterior de arrays; la primera fila contiene nueve encabezados y las siguientes 495 contienen registros. **No es JSON Lines ni una lista de objetos.** La tabla Bronze ya fue poblada, así que **no repetir la ingesta**.

### Columnas de la tabla Bronze

| Columna | Significado | Tratamiento en Staging |
|---|---|---|
| `NAME` | Nombre descriptivo del census tract | `census_tract_name` |
| `B19013_001E` | Ingreso **mediano anual por hogar**, USD ajustados a 2024 | `median_household_income` |
| `B19013_001M` | Margen de error del ingreso mediano, al 90 % | `income_margin_of_error` |
| `B01003_001E` | Población total estimada | `population` |
| `B25077_001E` | Valor **mediano** de viviendas ocupadas por sus propietarios, USD | `median_home_value` |
| `B25058_001E` | Alquiler contractual **mediano mensual**, USD | `median_monthly_rent` |
| `STATE` | FIPS estado (`53`) | `state_fips` como texto de 2 caracteres |
| `COUNTY` | FIPS condado (`033`) | `county_fips` como texto de 3 caracteres |
| `TRACT` | FIPS tract (`000101`, etc.) | `tract_fips` como texto de 6 caracteres |
| `SOURCE_FILE` | Archivo de origen | Conservar si es la convención de Staging actual |
| `BATCH_ID` | Lote de ingesta | Conservar si es la convención de Staging actual |
| `INGESTED_AT` | Timestamp de ingesta | Conservar **obligatoriamente** para incrementalidad Silver |

**Clave de negocio principal:** `census_tract_geoid = state_fips || county_fips || tract_fips`, de 11 caracteres. Conservar ceros iniciales. No usar `NAME` como clave, no castear GEOID a número y no usar `tract_fips` sin estado/condado.

## 2. Calidad y limpieza necesaria

Estas comprobaciones se han hecho sobre el archivo `rentas.json` aportado:

| Campo original | Código especial / marcador | Nº de filas | Acción propuesta |
|---|---|---:|---|
| `B19013_001E` | `-666666666` | 2 | Interpretar como ausencia de estimación (`NULL`) |
| `B19013_001M` | `-333333333` | 20 | Interpretar como margen de error no disponible / limitado (`NULL`) |
| `B19013_001M` | `-222222222` | 2 | Interpretar como margen de error no aplicable (`NULL`) |
| `B25077_001E` | `-666666666` | 8 | `NULL` |
| `B25058_001E` | `-666666666` | 10 | `NULL` |
| `B19013_001E` | `250001` | 20 | **Marcador de límite superior**; conservar indicador `income_top_coded` |
| `B25077_001E` | `2000001` | 15 | **Marcador de límite superior**; conservar indicador `home_value_top_coded` |
| `B25058_001E` | `3501` | 15 | **Marcador de límite superior**; conservar indicador `rent_top_coded` |

Los tres marcadores superiores **no son cantidades medidas exactas**. Para evitar interpretaciones incorrectas, crear flags booleanos (`income_top_coded`, `home_value_top_coded`, `rent_top_coded`). Seguir una política coherente en Staging: conservar el marcador numérico con flag explícito, o poner el valor en `NULL` y guardar el umbral/flag; **documentar la elección** y evitar que Gold futuro lo use como valor exacto. Se recomienda conservarlo numéricamente con flag para permitir clasificar rentas altas sin perder información.

- Usar `TRY_TO_NUMBER` / `NULLIF` u operaciones equivalentes según las convenciones del proyecto.
- No inventar importes, rentas individuales, ZIP ni coordenadas.
- Revisar nulos y población cero antes de cualquier tasa por habitantes futura.
- No eliminar filas porque estén fuera de Seattle: todavía no tenemos una delimitación espacial confirmada de la ciudad.
- No limpiar Bronze: Bronze es la fuente cruda ya cargada.

## 3. Modelo Staging nuevo

Crear **solo** el modelo nuevo, con el nombre consistente con el repositorio (nombre sugerido: `stg_census_socioeconomic.sql`).

Responsabilidades:

1. Referenciar `DEV_BRONZE.RAW.BRZ_CENSUS_SOCIOECONOMIC` mediante `source()` si está ya declarada. Si no existe en el YAML de sources, **no modificar silenciosamente dicho YAML**: informar de que hace falta autorización para registrar la fuente, o utilizar la vía de acceso ya permitida en el proyecto y documentarla.
2. Renombrar todas las columnas semánticamente, normalizar tipos y limpiar códigos especiales.
3. Construir `census_tract_geoid` de 11 caracteres sin perder ceros.
4. Añadir los tres flags de valores limitados superiormente.
5. Mantener trazabilidad `source_file`, `batch_id`, `ingested_at` según las convenciones del repositorio.
6. Una fila por `census_tract_geoid` (si Bronze incorpora nuevas cargas, los duplicados se resolverán siguiendo el patrón existente en Silver, no arbitrariamente en Staging).
7. No geocodificar, no unir con otras tablas en Staging, no crear Gold.

Primero inspeccionar los modelos `stg_crimes`, `stg_arrests`, `stg_pet_licenses` y copiar su **estilo**, materialización y uso de macros de limpieza cuando correspondan. No escribir una nueva macro global.

## 4. Modelo Silver nuevo: grano, incrementalidad y relación geográfica

Nombre sugerido: `census_socioeconomic.sql` dentro de la carpeta Silver real. **Grano obligatorio: una fila por `census_tract_geoid`.**

Seguir el patrón ya adoptado en el proyecto para las tablas Silver:

```jinja
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='census_tract_geoid',
    on_schema_change='fail'
) }}
```

- Leer desde `ref('stg_census_socioeconomic')`, usando el nombre definitivo adoptado.
- En ejecuciones incrementales, filtrar con `ingested_at >= (SELECT MAX(ingested_at) FROM {{ this }})`, atendiendo al comportamiento con tabla vacía, como en los modelos existentes.
- Deduplicar mediante `QUALIFY ROW_NUMBER() OVER (PARTITION BY census_tract_geoid ORDER BY ingested_at DESC, ...) = 1`, respetando el desempate real que utilice el proyecto (no inventar una columna).
- Preservar `ingested_at` y la clave de negocio para futuras actualizaciones.
- Comprobar los tipos reales y las claves de los modelos Silver existentes antes de copiar el patrón.

### Requisito de integración con `postal_codes` o `full_address`

**El usuario quiere conectar esta nueva tabla económica con la geografía Silver existente, preferentemente aprovechando `postal_codes` o `full_address`, sin cambiar ninguna de esas tablas.**

**Advertencia técnica crítica:** el archivo ACS está indexado por **census tract**, no por ZIP/postal code ni por dirección o bloque. **No existe una equivalencia 1:1 garantizada entre tracts y ZIP**, y el JSON no incluye ninguna columna ZIP, dirección ni bloque. No hacer joins por similitud de nombres, por prefijos de números ni asignar un código postal arbitrario. Tampoco unir por `state` o `county` solamente, porque multiplicaría o asociaría registros erróneamente.

Procedimiento obligatorio:

1. Inspeccionar la definición y las columnas reales de `postal_codes` y `full_address` y de las tablas/relaciones que los alimentan.
2. Comprobar si alguna incluye **`census_tract_geoid` verificable** o un mapeo espacial ya resuelto entre tract y direcciones (o una tabla puente de tract↔ZIP respaldada por datos válidos).
3. **Si existe un mapeo exacto y validado**, priorizar `full_address` cuando su relación sea espacialmente precisa y no altere el grano de la nueva tabla. En la **nueva tabla Silver solamente**, incluir la FK existente que corresponda, sustituyendo el identificador geográfico crudo por esa FK **cuando la cardinalidad lo permita sin duplicar ni perder tracts**. Mantener `census_tract_geoid` como clave de negocio técnica aunque se añada FK geográfica.
4. **Si el mapeo es muchos-a-muchos**, no reducirlo artificialmente a una FK única. No crear asociaciones falsas ni multiplicar las 495 filas. Documentar que sería necesaria una tabla puente o polígonos TIGER/Line y un cruce geoespacial posterior. Esa solución queda **fuera del alcance de este encargo**.
5. **Si no existe un mapeo válido**, entregar Staging y Silver normalizados con `census_tract_geoid`, **sin FK inventada**; informar explícitamente del bloqueo geográfico y qué información adicional hace falta. No modificar `postal_codes` ni `full_address`, ni crear por tu cuenta más modelos de enlace.

> Es preferible una nueva tabla Silver correcta, todavía no enlazada, que una FK errónea que contamine el datamart de delitos.

## 5. Pruebas y validaciones

Comprobar, mediante `dbt parse`, compilación o ejecución **solo de los nuevos modelos** cuando el entorno lo permita:

- La tabla Bronze existe y contiene **495 registros** (el conteo real de Snowflake debe verificarse: 495 es lo esperado según el archivo original, no una ejecución confirmada aquí).
- `census_tract_geoid` es `NOT NULL`, tiene 11 caracteres y es único en Silver.
- Todas las claves comienzan por `53033` y conservan ceros.
- Las métricas económicas nunca quedan con códigos negativos especiales como si fueran importes.
- Los flags de límites superiores son coherentes con la fuente.
- Ningún join genera duplicados ni pierde zonas censales.
- Los 495 registros esperados llegan a Silver si la carga Bronze es completa y no hay errores.
- Ejecutar **únicamente los nuevos modelos** y los tests específicos nuevos; **no** ejecutar `dbt build` de todo el proyecto.
- Ejecutar `git diff --name-only` y `git diff` y comprobar que **únicamente hay archivos nuevos de este desarrollo**. Si existe un cambio previo no relacionado, **no revertirlo ni incluirlo en el trabajo**.

## 6. Entregables y criterio de aceptación

1. Nuevo modelo Staging de datos socioeconómicos con nombres limpios, GEOID y tratamiento explícito de códigos especiales.
2. Nuevo modelo Silver incremental siguiendo **exactamente** el patrón de `licenses.sql` y los demás modelos Silver actuales.
3. Tests/archivos nuevos estrictamente necesarios para validar estos dos modelos, sin tocar los existentes.
4. Informe final conciso de archivos añadidos, comandos ejecutados, filas contadas y decisión razonada respecto a `postal_codes` / `full_address`, con cualquier impedimento claramente señalado.
5. **Cero modificaciones en Bronze existente, `postal_codes`, `full_address`, Gold, macros globales, otras tablas, otros modelos o configuraciones existentes.**

**Parar en Silver. No hacer Gold ni el mart de correlaciones.**
