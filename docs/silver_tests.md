# Tests declarados en los YAML de Silver

Los 18 modelos se documentan en siete archivos, uno por dominio:

- [`arrests/_arrests.yml`](../models/silver/arrests/_arrests.yml)
- [`crimes/_crimes.yml`](../models/silver/crimes/_crimes.yml)
- [`geography/_geography.yml`](../models/silver/geography/_geography.yml)
- [`persons/_persons.yml`](../models/silver/persons/_persons.yml)
- [`pet_licenses/_pet_licenses.yml`](../models/silver/pet_licenses/_pet_licenses.yml)
- [`reports/_reports.yml`](../models/silver/reports/_reports.yml)
- [`socioeconomic/_socioeconomic.yml`](../models/silver/socioeconomic/_socioeconomic.yml)

Hay **79 tests de datos y ningún test unitario de Silver**. Este recuento corresponde
solo a estos YAML: las pruebas singulares SQL, las integraciones y los tests de otras
capas no se han eliminado ni se incluyen en el total.

## Claves: 17 `unique` y 17 `not_null`

Ambos controles se aplican a cada clave de esta tabla. `unique` evita duplicar
entidades y multiplicar los resultados de los joins; `not_null` exige una identidad
utilizable. Uno no sustituye al otro, porque `unique` no rechaza los nulos.

| Modelo | Clave |
| --- | --- |
| `arrest` | `arrest_number` |
| `arrest_offenses` | `arrest_offense_id` |
| `arrest_types` | `arrest_type_id` |
| `cad_profiles` | `cad_profile_id` |
| `offense_types` | `offense_type_id` |
| `crimes` | `crime_id` |
| `nibrs` | `nibrs_key` |
| `offense_categories` | `offense_category_id` |
| `shooting_types` | `shooting_type_id` |
| `full_address` | `address_id` |
| `police_add` | `police_area_id` |
| `postal_codes` | `cp` |
| `agents` | `agent_key` |
| `subject` | `subject_key` |
| `licenses` | `license_number` |
| `reports` | `report_id` |
| `census_socioeconomic` | `cp` |

## Otros campos obligatorios: 21 `not_null`

| Modelo | Columnas | Motivo |
| --- | --- | --- |
| `arrest` | `ingested_at`, `address_id` | Cursor incremental y referencia obligatoria, con UNKNOWN o REDACTED si corresponde. |
| `arrest_offenses` | `arrest_number`, `nibrs_match_status` | Todo cargo pertenece a una detención y declara cómo se resolvió NIBRS. |
| `arrest_types` | `description` | Un hash no nulo no garantiza que exista el texto que identifica el tipo. |
| `offense_types` | `offense_type`, `parse_status` | Conservación del texto legal que define la identidad y del resultado de parsing. |
| `crimes` | `report_id`, `offense_id`, `ingested_at`, `address_id` | Identidad informe-delito, cursor incremental y ubicación obligatoria. |
| `crime_shooting_types` | `crime_id`, `shooting_type_id` | Una asociación requiere ambos extremos. |
| `nibrs` | `offense_code` | El código define la identidad; no basta con que exista su hash. |
| `shooting_types` | `description` | La etiqueta define el tipo de tiroteo. |
| `full_address` | `cp_status` | Un CP ausente debe tener un estado interpretable. |
| `agents` | `officer_id` | No crear una identidad de agente a partir de un identificador ausente. |
| `subject` | `sk_person`, `ingested_at` | Identificador de origen usado por el incremental y su cursor. |
| `licenses` | `ingested_at` | Cursor necesario para seleccionar las siguientes ingestas. |
| `reports` | `report_number` | El número de origen define la identidad del informe. |

## Integridad referencial: 18 `relationships`

Cada referencia informada debe encontrar su destino. Estos tests evitan registros
huérfanos y pérdidas al unir tablas. Admiten nulos en las relaciones opcionales;
las obligatorias tienen además su `not_null` en el apartado anterior.

| Origen | Destino |
| --- | --- |
| `arrest.report_id` | `reports.report_id` |
| `arrest.arrest_type_id` | `arrest_types.arrest_type_id` |
| `arrest.agent_key` | `agents.agent_key` |
| `arrest.subject_key` | `subject.subject_key` |
| `arrest.address_id` | `full_address.address_id` |
| `arrest.police_area_id` | `police_add.police_area_id` |
| `arrest.cad_profile_id` | `cad_profiles.cad_profile_id` |
| `arrest_offenses.arrest_number` | `arrest.arrest_number` |
| `arrest_offenses.offense_type_id` | `offense_types.offense_type_id` |
| `arrest_offenses.nibrs_key` | `nibrs.nibrs_key` |
| `crimes.report_id` | `reports.report_id` |
| `crimes.nibrs_key` | `nibrs.nibrs_key` |
| `crimes.offense_category_id` | `offense_categories.offense_category_id` |
| `crimes.address_id` | `full_address.address_id` |
| `crimes.police_area_id` | `police_add.police_area_id` |
| `crime_shooting_types.crime_id` | `crimes.crime_id` |
| `crime_shooting_types.shooting_type_id` | `shooting_types.shooting_type_id` |
| `full_address.cp` | `postal_codes.cp` |

## Estados: 3 `accepted_values`

Evitan estados desconocidos que los consumidores no puedan interpretar. Se combinan
con `not_null`, porque la lista de valores aceptados no exige por sí sola un valor.

| Columna | Valores permitidos |
| --- | --- |
| `arrest_offenses.nibrs_match_status` | `matched`, `missing`, `ambiguous`, `unmatched` |
| `offense_types.parse_status` | `parsed`, `administrative`, `review_required` |
| `full_address.cp_status` | `matched`, `redacted`, `missing_coordinates`, `invalid_coordinates`, `no_match`, `ambiguous`, `boundary` |

## Tres controles de grano y coherencia

- **`dbt_utils.unique_combination_of_columns`** sobre
  `crime_shooting_types(crime_id, shooting_type_id)`: es la clave compuesta del puente;
  repetir una asociación multiplicaría los resultados al unirlo con delitos.
- **`dbt_utils.expression_is_true`** en `full_address`, con
  `(cp_status = 'matched') = (cp is not null)`: impide publicar un CP sin coincidencia
  válida o declarar una coincidencia sin CP.
- **`dbt_utils.expression_is_true`** en `offense_categories`, con
  `offense_category is not null or offense_sub_category is not null`: falla con
  severidad `error` si alguna fila tiene ambos niveles nulos. Permite combinaciones
  parciales. Se comprueba el resultado del modelo, además del filtro que ya aplica su SQL.

## Controles retirados

No se repiten en Silver las validaciones de formato, importes y marcadores ACS que
ya hace staging y que estos modelos no transforman. Tampoco se repiten las
comprobaciones de parsing, cobertura y resolución que ya tienen pruebas singulares.

No se exige unicidad ni presencia de la descripción NIBRS: puede faltar o ser
ambigua entre códigos. No se impone un formato único al número de informe, pues
staging conserva los formatos no reconocidos para revisión. No se fuerza una FK
desde `licenses.cp` ni desde `census_socioeconomic.cp` al catálogo postal local:
la cobertura puede ser parcial y ZCTA no equivale a ZIP.

`license_id` es un identificador alternativo que depende del nombre del animal,
no el grano del modelo; los tests de clave se aplican a `license_number`.

## Validación de esta reorganización

`dbt parse` con dbt Core 1.12.7 y perfil temporal sin conexión confirma los 18 modelos,
los 79 tests de datos y la ausencia de unitarios de Silver en el manifest.
Pasan las regresiones locales de clasificación de delitos, direcciones y contexto
del agente. El comprobador de normalización no se pudo ejecutar porque falta
`duckdb` en el entorno.

Estas comprobaciones no ejecutan los 79 tests contra datos reales. Queda pendiente
`dbt test --select path:models/silver` en un entorno Snowflake configurado.
