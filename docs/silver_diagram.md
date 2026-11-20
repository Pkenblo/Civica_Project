# Referencia del modelo Silver

El diccionario, el bloque DBML y el [diagrama SVG](silver_diagram.svg) describen los modelos dbt del repositorio. No certifican que estén desplegados ni que todas las pruebas hayan pasado en Snowflake. Para la consolidación incremental de detenciones, véase [Detenciones en Silver](arrests.md).

## Cambios de esta revisión

- `Crimes` guarda dos referencias: `offense_category_id` y `offense_subcategory_id`. Cada subcategoría informada conserva su categoría de origen cuando está disponible. `NIBRS` es una clasificación distinta y no se enlaza con esos catálogos.
- `Arrest` consolida una fila por detención, guarda las edades del sujeto y del agente y referencia `Cad_profiles`. `Arrest_conflicts` expone las discrepancias entre versiones.
- `Full_address` conserva el CP opcional y añade `cp_status`, que explica el resultado de la asignación sin mezclar motivos con códigos postales.
- Se elimina del diseño `Address_postal_assignment`: no se necesita una tabla adicional para guardar únicamente el estado que interesa consultar.
- `Postal_codes` sustituye a `Address_cp` y almacena una única geometría activa por CP. Las distintas piezas del mismo código se unen en un Polygon o MultiPolygon.
- `Full_address.cp` y `Licencia.cp` apuntan directamente a `Postal_codes.cp`.
- `ref_zipcode_areas` y `ref_zipcode_versions` dejan de formar parte de este diseño simplificado. El archivo cartográfico y sus metadatos de procedencia deben conservarse en la ingesta, identificados por `boundary_version`.
- No se persisten la fecha de evaluación, el número de candidatos ni la versión cartográfica por dirección. El número de candidatos se calcula durante la transformación para clasificar el resultado, pero no es una columna Silver.
- No se modela un histórico de asignaciones ni varias geometrías simultáneas por CP. `Postal_codes.boundary_version` identifica las geometrías actuales; no permite reconstruir por sí sola las evaluaciones anteriores o la versión utilizada para un registro sin CP.

## Guía de lectura

- El diccionario y el DBML conservan la capitalización histórica de los nombres; el SVG muestra los nombres de los modelos dbt en minúsculas.
- `PK`: clave lógica. En `Crime_shooting_types` y `Arrest_conflicts` es compuesta. `Crimes.offense_id` identifica el delito, pero no es una PK declarada: el modelo todavía conserva variantes.
- `FK → Tabla.campo`: clave foránea hacia el atributo indicado.
- `UQ` (`UK` en el SVG): unicidad prevista o comprobada por un test declarado. No implica una segunda PK.
- `NN`: no nulidad explícita en esta referencia. `—` indica que no se declara aquí. Las PK del diseño implican no nulidad, aunque no lleven la marca `NN`.
- `1:N`: un registro de la tabla padre puede relacionarse con varios de la hija. No significa que todo padre deba tener al menos un hijo.

## Inventario

El diagrama contiene **19 modelos, 100 columnas y 21 relaciones lógicas**. Los conteos incluyen la vista `Arrest_conflicts`.

| Tabla | Columnas | Clave primaria | Función interpretada |
| --- | ---: | --- | --- |
| `Reports` | 3 | `report_id` | Referencia común de informes policiales. |
| `Crimes` | 8 | `offense_id` (grano pendiente) | Delitos, sus clasificaciones y su ubicación. |
| `Offense_categories` | 2 | `offense_category_id` | Catálogo de categorías de delitos. |
| `Offense_subcategories` | 3 | `offense_subcategory_id` | Catálogo de subcategorías por categoría de origen. |
| `Arrest` | 23 | `arrest_number` | Detenciones consolidadas y sus datos operativos. |
| `Cad_profiles` | 4 | `cad_profile_id` | Combinaciones observadas de datos de despacho CAD. |
| `Arrest_conflicts` | 6 | (`arrest_number`, `field_name`) | Vista de valores contradictorios entre versiones. |
| `Crime_shooting_types` | 2 | (`offense_id`, `shooting_type_id`) | Puente entre delitos y tipos de tiroteo. |
| `Shooting_types` | 2 | `shooting_type_id` | Catálogo de tipos de tiroteo. |
| `NIBRS` | 5 | `nibrs_key` | Clasificación NIBRS de delitos. |
| `Arrest_offenses` | 4 | `arrest_offense_id` | Infracciones asociadas a un arresto. |
| `Offense_types` | 2 | `offense_type_id` | Catálogo de tipos de infracción de arresto. |
| `Arrest_types` | 2 | `arrest_type_id` | Catálogo de tipos de arresto. |
| `Agents` | 6 | `agent_key` | Datos de agentes. |
| `Subject` | 4 | `subject_key` | Datos de sujetos vinculados a arrestos. |
| `Full_address` | 9 | `address_id` | Ubicación publicada, CP asignado y estado de la asignación. |
| `Police_Add` | 4 | `police_area_id` | Área policial y sus divisiones. |
| `Postal_codes` | 3 | `cp` | Catálogo postal común y geometría activa opcional de cada CP. |
| `Licencia` | 8 | `license_number` | Licencias de animales y su código postal. |

## Tablas y atributos

### Reports

Grano interpretado: un registro por `report_id`. El número de informe tiene una marca de unicidad.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `report_id` | `varchar` | PK | — | Identificador del informe. |
| `report_number` | `varchar` | UQ | Sí | Número del informe. |
| `report_date_time` | `timestamp_ntz` | — | — | Fecha y hora del informe, tomada de delitos si está disponible. |

Referenciada por `Crimes.report_id` y `Arrest.report_id`.

### Crimes

`offense_id` identifica el delito, no el informe. El modelo elimina duplicados completos, pero puede conservar varias filas de un mismo `offense_id` si tienen atributos distintos. La fecha del informe se consulta en `Reports`.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `offense_id` | `varchar` | ID; grano pendiente | Sí | Identificador del delito. |
| `report_id` | `varchar` | FK → `Reports.report_id` | — | Informe asociado. |
| `offense_date` | `timestamp_ntz` | — | — | Fecha y hora del delito; el tipo incluye hora aunque el nombre termine en `_date`. |
| `nibrs_key` | `varchar` | FK → `NIBRS.nibrs_key` | — | Clasificación NIBRS asociada. |
| `offense_category_id` | `varchar` | FK → `Offense_categories.offense_category_id` | — | Categoría del delito; se conserva aunque falte la subcategoría. |
| `offense_subcategory_id` | `varchar` | FK → `Offense_subcategories.offense_subcategory_id` | — | Subcategoría del delito dentro de la categoría informada. |
| `address_id` | `varchar` | FK → `Full_address.address_id` | — | Dirección asociada al delito. |
| `police_area_id` | `varchar` | FK → `Police_Add.police_area_id` | — | Área policial asociada al delito. |

`Crime_shooting_types.offense_id` referencia este identificador de forma provisional, hasta que `Crimes` garantice una sola fila por `offense_id`.

### Offense_categories

Una fila por categoría informada de delito. No equivale a `NIBRS.crime_against_category`.

| Atributo | Tipo | Claves / restricciones | NN | Significado |
| --- | --- | --- | --- | --- |
| `offense_category_id` | `varchar` | PK | Sí | Clave generada a partir del nombre normalizado. |
| `offense_category` | `varchar` | UQ | Sí | Etiqueta de categoría, como `PROPERTY CRIME`. |

### Offense_subcategories

Una fila por combinación de categoría y etiqueta. Si falta la categoría, la subcategoría se conserva con la referencia nula. En el CSV de ejemplo se observaron tres categorías y 31 subcategorías, cada una con una sola categoría. El modelo no da por hecho que esa correspondencia se mantenga en futuras cargas.

| Atributo | Tipo | Claves / restricciones | NN | Significado |
| --- | --- | --- | --- | --- |
| `offense_subcategory_id` | `varchar` | PK | Sí | Clave de la combinación de categoría y etiqueta. |
| `offense_category_id` | `varchar` | FK → `Offense_categories.offense_category_id` | — | Categoría a la que pertenece la subcategoría observada. |
| `offense_sub_category` | `varchar` | UQ junto con `offense_category_id` | Sí | Etiqueta de subcategoría, como `BURGLARY`. |

### Arrest

Una fila por `arrest_number`, clave del `MERGE`. Para cada campo gana el valor no nulo de la ingesta más reciente. Las referencias a agente y sujeto representan las identidades consolidadas de esa detención.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `arrest_number` | `varchar` | PK | — | Número identificador del arresto. |
| `last_ingested_at` | `timestamp_ltz` | — | Sí | Fecha de la última ingesta de la detención. |
| `source_version_count` | `number` | — | Sí | Número de versiones normalizadas distintas. |
| `source_signature` | `varchar` | — | Sí | Firma del histórico de versiones de RAW. |
| `max_completeness_score` | `number` | — | Sí | Mayor número de campos informados en una versión; no decide qué valores ganan. |
| `consolidation_conflicts` | `object` | — | Sí | Valores candidatos incompatibles por campo. |
| `consolidation_choices` | `object` | — | Sí | Valores seleccionados antes de generar las referencias. |
| `arrest_occurred_date_time` | `timestamp_ntz` | — | — | Fecha y hora en que ocurrió el arresto. |
| `arrest_reported_date_time` | `timestamp_ntz` | — | — | Fecha y hora de comunicación o registro del arresto. |
| `report_id` | `varchar` | FK → `Reports.report_id` | — | Informe asociado. |
| `arrest_type_id` | `varchar` | FK → `Arrest_types.arrest_type_id` | — | Tipo de arresto. |
| `agent_key` | `varchar` | FK → `Agents.agent_key` | — | Agente asociado. |
| `subject_key` | `varchar` | FK → `Subject.subject_key` | — | Sujeto asociado. |
| `address_id` | `varchar` | FK → `Full_address.address_id` | Sí | Dirección asociada al arresto. |
| `police_area_id` | `varchar` | FK → `Police_Add.police_area_id` | — | Área policial asociada al arresto. |
| `crisis_involved` | `boolean` | — | — | Indicador de crisis. |
| `complaint_involved` | `boolean` | — | — | Indicador de queja o denuncia; definición exacta no especificada. |
| `force_involved` | `boolean` | — | — | Indicador de uso de fuerza. |
| `terry_stop` | `boolean` | — | — | Indicador de una intervención de tipo Terry stop. |
| `demonstration` | `boolean` | — | — | Indicador de manifestación. |
| `subgect_age_at_detention` | `varchar` | — | — | Rango de edad del sujeto en la detención; se mantiene el nombre de columna del modelo. |
| `agents_age_at_detention` | `number(38,0)` | — | — | Edad del agente en la detención. |
| `cad_profile_id` | `varchar` | FK → `Cad_profiles.cad_profile_id` | — | Perfil CAD; nulo si faltan sus tres atributos. |

Referenciada por `Arrest_offenses.arrest_number` y por la vista `Arrest_conflicts`.

### Cad_profiles

Una fila por combinación de datos de despacho (*Computer-Aided Dispatch*) consolidada en `Arrest`. Puede contener campos nulos. Compartir perfil no implica compartir llamada: la fuente no aporta un identificador de llamada CAD.

| Atributo | Tipo | Claves / restricciones | NN | Significado |
| --- | --- | --- | --- | --- |
| `cad_profile_id` | `varchar` | PK | Sí | Clave de la combinación de cierre, tipo inicial y prioridad. |
| `cad_clearance` | `varchar` | — | — | Resultado o cierre de la intervención. |
| `cad_initial_call_type` | `varchar` | — | — | Tipo inicial registrado por el sistema de despacho. |
| `cad_priority` | `number(38,0)` | — | — | Código de prioridad; la escala no está documentada aquí. |

### Arrest_conflicts

Vista con una fila por detención y campo en conflicto.

| Atributo | Tipo | Claves / restricciones | NN | Significado |
| --- | --- | --- | --- | --- |
| `arrest_number` | `varchar` | PK (parte 1); FK → `Arrest.arrest_number` | Sí | Detención consolidada. |
| `field_name` | `varchar` | PK (parte 2) | Sí | Campo con valores contradictorios. |
| `observed_values` | `variant` | — | — | Valores candidatos. |
| `selected_value` | `variant` | — | — | Valor publicado. |
| `max_completeness_score` | `number` | — | — | Métrica de completitud de las versiones. |
| `last_ingested_at` | `timestamp_ltz` | — | — | Última ingesta de la detención. |

### Crime_shooting_types

Grano: una combinación de delito y tipo de tiroteo. Los dos campos forman la PK y son, a la vez, FK. Esta tabla resuelve la relación N:M entre `Crimes` y `Shooting_types`.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `offense_id` | `varchar` | PK (parte 1); FK → `Crimes.offense_id` | Sí | Delito asociado. |
| `shooting_type_id` | `varchar` | PK (parte 2); FK → `Shooting_types.shooting_type_id` | Sí | Tipo de tiroteo asociado. |

La unicidad corresponde a la pareja, no a cada columna por separado.

### Shooting_types

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `shooting_type_id` | `varchar` | PK | — | Identificador del tipo de tiroteo. |
| `description` | `varchar` | UQ | Sí | Descripción del tipo de tiroteo. |

Referenciada por `Crime_shooting_types.shooting_type_id`.

### NIBRS

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `nibrs_key` | `varchar` | PK | — | Clave de la clasificación NIBRS. |
| `offense_code` | `varchar` | UQ | Sí | Código del delito. |
| `offense_description` | `varchar` | — | — | Descripción del delito. |
| `group_ab` | `varchar` | — | — | Grupo A/B de la clasificación. |
| `crime_against_category` | `varchar` | — | — | Categoría según el objeto del delito. |

Referenciada por `Crimes.nibrs_key`. En la muestra, los 64 códigos informados se corresponden cada uno con una categoría y subcategoría, pero hay 1.643 filas con categoría y sin código NIBRS. Por eso la categoría no se obtiene a través de `NIBRS`. Tampoco hay una FK desde `Arrest_offenses` a `NIBRS`.

### Arrest_offenses

Grano interpretado: una infracción asociada a un arresto, identificada por `arrest_offense_id`. No se marca como única la pareja (`arrest_number`, `offense_type_id`).

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `arrest_offense_id` | `varchar` | PK | — | Identificador de la infracción asociada al arresto. |
| `arrest_number` | `varchar` | FK → `Arrest.arrest_number` | Sí | Arresto asociado. |
| `offense_type_id` | `varchar` | FK → `Offense_types.offense_type_id` | — | Tipo de infracción. |
| `nibrs_description` | `varchar` | — | — | Descripción NIBRS almacenada como texto, sin FK dibujada hacia `NIBRS`. |

Permite varias infracciones por arresto y reutilizar un tipo de infracción en distintos arrestos.

### Offense_types

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `offense_type_id` | `varchar` | PK | — | Identificador del tipo de infracción. |
| `offense_type` | `varchar` | UQ | Sí | Nombre o descripción del tipo de infracción. |

Referenciada por `Arrest_offenses.offense_type_id`. Es un catálogo distinto de `Shooting_types`, `Arrest_types` y `NIBRS`.

### Arrest_types

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `arrest_type_id` | `varchar` | PK | — | Identificador del tipo de arresto. |
| `description` | `varchar` | UQ | Sí | Descripción del tipo de arresto. |

Referenciada por `Arrest.arrest_type_id`.

### Agents

Una fila por combinación observada de identificador, género, raza, unidad y cargo. No representa vigencias históricas; la edad se guarda en `Arrest`.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `agent_key` | `varchar` | PK | — | Clave del agente en el modelo. |
| `officer_id` | `varchar` | — | Sí | Identificador del agente; no lleva marca de unicidad. |
| `officer_gender` | `varchar` | — | — | Género del agente. |
| `officer_race` | `varchar` | — | — | Raza del agente según la clasificación del origen. |
| `squad_description` | `varchar` | — | — | Descripción de la unidad o escuadrón. |
| `officer_title` | `varchar` | — | — | Cargo o rango del agente. |

Referenciada por `Arrest.agent_key`.

### Subject

Una fila por combinación observada de identificador, género y raza. El rango de edad se guarda en `Arrest`.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `subject_key` | `varchar` | PK | — | Clave del sujeto en el modelo. |
| `sk_person` | `varchar` | — | Sí | Identificador de persona; no lleva marca de unicidad ni FK dibujada. |
| `subject_gender` | `varchar` | — | — | Género del sujeto. |
| `subject_race` | `varchar` | — | — | Raza del sujeto según la clasificación del origen. |

Referenciada por `Arrest.subject_key`. No aparece una tabla `Person` en el diagrama.

### Full_address

Grano previsto: una ubicación publicada normalizada, conservando su contexto. Guarda `cp` y `cp_status` en la misma fila, sin una tabla adicional de evaluación. El CP no se añade directamente a `Crimes` o `Arrest`: ambos lo consultan mediante `address_id`.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `address_id` | `varchar` | PK | — | Identificador de la dirección. |
| `block_address` | `varchar` | — | — | Dirección expresada a nivel de bloque o manzana. |
| `latitude` | `number(18,5)` | — | — | Latitud normalizada en staging. Uso previsto: EPSG:4326, sujeto a confirmar los metadatos del origen policial. |
| `longitude` | `number(18,5)` | — | — | Longitud normalizada en staging. Es el primer argumento al construir el punto espacial. |
| `neighborhood` | `varchar` | — | — | Barrio. |
| `reporting_area` | `varchar` | — | — | Área de reporte. |
| `census_block_2020` | `varchar` | — | — | Bloque censal de 2020. |
| `cp` | `varchar` | FK → `Postal_codes.cp` | — | CP de la zona que contiene el punto publicado. Solo informado con `cp_status = 'matched'`; en los demás casos es nulo, nunca un mensaje como `Redacted`. |
| `cp_status` | `varchar` | Uno de los siete estados definidos debajo | Sí | Resultado de la asignación o motivo por el que el CP queda nulo. |

Referenciada por `Crimes.address_id` y `Arrest.address_id`.

`address_id` no depende del CP, del estado postal ni de la versión cartográfica. La normalización debe conservar el contexto de la ubicación publicada y distinguir una ubicación ocultada de otra simplemente ausente; no agrupar todos los valores nulos como si fueran una dirección real compartida. Este cambio no resuelve la identidad general de direcciones ni su historización.

El polígono se almacena una sola vez en `Postal_codes`, no en cada dirección. La pertenencia del punto al polígono se calcula durante la transformación: no es una FK adicional. `cp` y `cp_status` deben calcularse y publicarse conjuntamente usando la cartografía activa.

#### Estados postales

| `cp_status` | Situación | `Full_address.cp` |
| --- | --- | --- |
| `redacted` | La ubicación está marcada como ocultada. Tiene prioridad sobre el resto de estados. | Nulo |
| `missing_coordinates` | Falta alguna coordenada y no hay marca de ocultación. | Nulo |
| `invalid_coordinates` | Las coordenadas son inutilizables según las reglas de validación aprobadas. | Nulo |
| `no_match` | Se intenta el cruce, pero ninguna zona cubre el punto. | Nulo |
| `ambiguous` | Más de un CP distinto cubre el punto. | Nulo |
| `boundary` | Un único CP cubre el punto, pero está exactamente en su límite. | Nulo |
| `matched` | Un único CP contiene el punto en su interior. | CP encontrado |

El número de candidatos se obtiene como dato intermedio para distinguir estos casos; no se almacena en la tabla. Un punto fuera de Seattle no es inválido por ese motivo. Estar fuera de la cobertura cartográfica puede producir `no_match` sin que las coordenadas sean erróneas. Las reglas de plausibilidad regional deben definirse expresamente antes de clasificar anomalías como `invalid_coordinates`.

### Police_Add

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `police_area_id` | `varchar` | PK | — | Identificador del área policial. |
| `precinct` | `varchar` | — | — | Distrito policial. |
| `sector` | `varchar` | — | — | Sector policial. |
| `beat` | `varchar` | — | — | Zona de patrulla. |

Referenciada por `Crimes.police_area_id` y `Arrest.police_area_id`. No hay FK directa entre `Police_Add` y `Full_address` o `Postal_codes`.

### Postal_codes

Sustituye a `Address_cp`. Grano: una fila por código postal, con su geometría de la cartografía activa si está disponible. No hay una fila por pieza geográfica ni por versión histórica.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `cp` | `varchar` | PK | — | Código postal. |
| `geography` | `geography` | Polygon o MultiPolygon válido en EPSG:4326, o nulo | — | Unión de las piezas geográficas del CP en el mapa activo. No es un centroide. |
| `boundary_version` | `varchar` | Identificador de procedencia; no es FK | — | Versión de la geometría activa. Nula si no se dispone de geometría. |

Referenciada directamente por `Full_address.cp` y `Licencia.cp`. Es la conexión geográfica entre licencias y datos policiales.

El catálogo reúne los CP con formato válido de las licencias, los de la cartografía activa y los códigos que sea necesario conservar por estar referenciados. Si un CP solo aparece en licencias y no tiene polígono en la cobertura local, se mantiene con `geography` y `boundary_version` nulos. Esto no impide relacionar la licencia con el catálogo.

Todas las geometrías no nulas deben pertenecer a una misma versión activa. `geography` y `boundary_version` deben ser ambas nulas o ambas no nulas. `boundary_version` no es una clave única: la misma descarga proporciona las geometrías de muchos CP. No se dibuja una FK entre columnas de versión no únicas.

La presencia de un CP en el catálogo acredita su formato y procedencia, no una verificación independiente contra USPS. No limitarlo a Seattle ni completar códigos inválidos por suposición.

### Licencia

Grano interpretado: un registro por `license_number`, no necesariamente por animal. No hay un identificador de animal independiente en el diagrama.

| Atributo | Tipo | Claves / restricciones | NN | Significado interpretado |
| --- | --- | --- | --- | --- |
| `license_id` | `varchar` | UQ | Sí | Hash del número de licencia y el nombre del animal. |
| `license_number` | `varchar` | PK | — | Número de licencia. |
| `license_issue_date` | `date` | — | — | Fecha de expedición de la licencia. |
| `animal_name` | `varchar` | — | — | Nombre del animal. |
| `species` | `varchar` | — | — | Especie. |
| `primary_breed` | `varchar` | — | — | Raza principal. |
| `secondary_breed` | `varchar` | — | — | Raza secundaria. |
| `cp` | `varchar` | FK → `Postal_codes.cp` | — | Código postal asociado a la licencia. |

El CP de licencias procede de `stg_pet_licenses.zip_code`, no de un cruce espacial. Los códigos vacíos o de formato inválido se tratan como incidencias; no se completan ni corrigen por suposición. No se añade aquí `cp_status`, porque esta revisión solo define el estado de la asignación espacial de las ubicaciones policiales.

## Relaciones completas

Una FK opcional permite que la fila hija no tenga padre asociado. Estas relaciones son lógicas: el diagrama no acredita integridad referencial ni implica que Snowflake imponga las restricciones.

| # | Padre | Hija | Tipo | Condición de unión |
| --- | --- | --- | --- | --- |
| 1 | `Reports` | `Crimes` | 1:N | `Reports.report_id = Crimes.report_id` |
| 2 | `Reports` | `Arrest` | 1:N | `Reports.report_id = Arrest.report_id` |
| 3 | `NIBRS` | `Crimes` | 1:N | `NIBRS.nibrs_key = Crimes.nibrs_key` |
| 4 | `Full_address` | `Crimes` | 1:N | `Full_address.address_id = Crimes.address_id` |
| 5 | `Police_Add` | `Crimes` | 1:N | `Police_Add.police_area_id = Crimes.police_area_id` |
| 6 | `Crimes` | `Crime_shooting_types` | 1:N | `Crimes.offense_id = Crime_shooting_types.offense_id` |
| 7 | `Shooting_types` | `Crime_shooting_types` | 1:N | `Shooting_types.shooting_type_id = Crime_shooting_types.shooting_type_id` |
| 8 | `Arrest` | `Arrest_offenses` | 1:N | `Arrest.arrest_number = Arrest_offenses.arrest_number` |
| 9 | `Offense_types` | `Arrest_offenses` | 1:N | `Offense_types.offense_type_id = Arrest_offenses.offense_type_id` |
| 10 | `Arrest_types` | `Arrest` | 1:N | `Arrest_types.arrest_type_id = Arrest.arrest_type_id` |
| 11 | `Agents` | `Arrest` | 1:N | `Agents.agent_key = Arrest.agent_key` |
| 12 | `Subject` | `Arrest` | 1:N | `Subject.subject_key = Arrest.subject_key` |
| 13 | `Full_address` | `Arrest` | 1:N | `Full_address.address_id = Arrest.address_id` |
| 14 | `Police_Add` | `Arrest` | 1:N | `Police_Add.police_area_id = Arrest.police_area_id` |
| 15 | `Postal_codes` | `Full_address` | 1:N | `Postal_codes.cp = Full_address.cp` |
| 16 | `Postal_codes` | `Licencia` | 1:N | `Postal_codes.cp = Licencia.cp` |
| 17 | `Offense_categories` | `Crimes` | 1:N | `Offense_categories.offense_category_id = Crimes.offense_category_id` |
| 18 | `Offense_subcategories` | `Crimes` | 1:N | `Offense_subcategories.offense_subcategory_id = Crimes.offense_subcategory_id` |
| 19 | `Offense_categories` | `Offense_subcategories` | 1:N | `Offense_categories.offense_category_id = Offense_subcategories.offense_category_id` |
| 20 | `Cad_profiles` | `Arrest` | 1:N | `Cad_profiles.cad_profile_id = Arrest.cad_profile_id` |
| 21 | `Arrest` | `Arrest_conflicts` | 1:N | `Arrest.arrest_number = Arrest_conflicts.arrest_number` |

### Mapa de navegación

```text
Reports (1) ──< Crimes (N)
Reports (1) ──< Arrest (N)

NIBRS (1) ──< Crimes (N)
Offense_categories (1) ──< Offense_subcategories (N)
Offense_categories (1) ──< Crimes (N)
Offense_subcategories (1) ──< Crimes (N)
Crimes (1) ──< Crime_shooting_types (N) >── (1) Shooting_types

Arrest (1) ──< Arrest_offenses (N) >── (1) Offense_types
Arrest_types (1) ──< Arrest (N)
Agents (1) ──< Arrest (N)
Subject (1) ──< Arrest (N)
Cad_profiles (1) ──< Arrest (N)
Arrest (1) ──< Arrest_conflicts (N)

Full_address (1) ──< Crimes (N)
Full_address (1) ──< Arrest (N)
Police_Add (1) ──< Crimes (N)
Police_Add (1) ──< Arrest (N)

Postal_codes (1) ──< Full_address (N)
Postal_codes (1) ──< Licencia (N)
```

La pertenencia espacial `punto de Full_address dentro de Postal_codes.geography` se utiliza para calcular el CP; no añade otra FK. Las licencias se conectan directamente al catálogo postal, sin pasar por una dirección policial ni por una tabla de evaluación.

## Proceso postal previsto

1. Descargar la cartografía de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area), exportarla a EPSG:4326 y conservar el archivo con sus metadatos y una versión identificable. La capa original utiliza EPSG:2926; no interpretar sus coordenadas nativas como longitud y latitud.
2. Validar la descarga completa y unir todas las piezas de cada CP. Preparar una fila por código en `Postal_codes`, con su Polygon o MultiPolygon de la única versión activa. Añadir los CP de licencias que falten, aunque no tengan geometría.
3. Preparar las ubicaciones policiales conservando el contexto de ocultación de staging. Confirmar el sistema de referencia del origen policial antes de construir puntos con `ST_MAKEPOINT(longitude, latitude)`.
4. Omitir el cruce de ubicaciones ocultadas o sin coordenadas utilizables y registrar el motivo. Para las elegibles, usar `ST_COVERS` para detectar candidatos y `ST_CONTAINS` para distinguir un punto interior de otro situado exactamente en el límite.
5. Contar CP distintos, aplicar los estados definidos y producir una sola evaluación por ubicación. No asignar el CP más cercano ni elegir arbitrariamente entre varios candidatos.
6. Publicar `Full_address.cp` y `Full_address.cp_status` conjuntamente. Conservar todas las ubicaciones y los hechos aunque su CP quede nulo. Al cambiar la cartografía activa, recalcular las asignaciones, incluidas las que antes no encontraban zona, y coordinar la publicación del catálogo y las direcciones para no mezclar resultados de mapas distintos.

Este proceso no proporciona el CP postal exacto de una dirección enmascarada ni los límites históricos vigentes en la fecha de cada suceso. Describe la zona del punto publicado usando el mapa elegido. La regla de límite exacto tampoco elimina la incertidumbre de una ubicación aproximada cercana a una frontera.

## Criterios para consultas e implementación

### Uniones y riesgo de duplicar medidas

- `Crimes` y `Arrest` comparten `Reports`, pero no tienen una FK directa entre sí. Unirlos por `report_id` produce todas las combinaciones de delitos y arrestos del mismo informe: si hay C delitos y A arrestos, pueden resultar C × A filas. No demuestra qué arresto corresponde a qué delito concreto.
- Unir un delito con `Crime_shooting_types` puede repetirlo una vez por tipo asociado. Unir un arresto con `Arrest_offenses` puede repetirlo una vez por infracción. Para contar delitos o arrestos, respetar sus claves o agregar las tablas hijas antes de unir.
- `Licencia` se conecta con los hechos policiales a través del código postal (`Licencia → Postal_codes ← Full_address ← Crimes/Arrest`). Es una asociación geográfica, no una relación entre un animal y un delito, arresto o persona. Una unión al detalle puede multiplicar filas; conviene agregar cada dominio por `cp` antes de compararlos.
- `Crimes.address_id` y `Arrest.address_id` describen ubicaciones de registros distintos; compartir informe no implica compartir dirección. Lo mismo se aplica a `police_area_id`.
- Para consultar la categoría de un delito, usar `Crimes.offense_category_id`. No exigir que haya subcategoría ni código NIBRS: ambas referencias pueden ser nulas.
- No sustituir `Agents.agent_key` por `officer_id`, ni `Subject.subject_key` por `sk_person`, sin validar antes la correspondencia y su unicidad.
- Para el enriquecimiento postal se conservan todas las ubicaciones, aunque no haya coincidencia: usar una estrategia equivalente a `LEFT JOIN` y producir un único resultado por ubicación. Las demás consultas requieren elegir el tipo de unión según su objetivo.
- Repetir el valor de un CP como FK en distintas direcciones o licencias es normal; lo que no se repite en cada una de ellas es el polígono. El estado postal se consulta directamente en `Full_address`, sin una unión adicional ni una tabla de auditoría que no se necesita en este alcance.

### Tipos y restricciones

- `timestamp_ntz` representa fecha y hora sin zona horaria. La última ingesta de `Arrest` se conserva como `timestamp_ltz`.
- Los códigos postales son `varchar`, no enteros. No convertirlos automáticamente a números ni perder posibles ceros iniciales.
- Las coordenadas se publican a cinco decimales desde staging. La precisión numérica no convierte una ubicación aproximada en una dirección exacta.
- Los cinco indicadores de `Arrest` son `boolean`: `crisis_involved`, `complaint_involved`, `force_involved`, `terry_stop` y `demonstration`. No se define si un nulo equivale a desconocido; no asumir que equivale a `false`.
- La PK de `Crime_shooting_types` debe validarse como combinación de columnas. `Arrest_offenses`, en cambio, usa una PK de una sola columna (`arrest_offense_id`).
- `Full_address.cp` es no nulo si y solo si `Full_address.cp_status = 'matched'`. En ese caso debe existir el CP en `Postal_codes` con geometría no nula y el punto debe corresponder a una única zona interior del mapa activo. Los demás estados conservan el CP nulo.
- La relación entre CP y estado, la integridad referencial, la validez de las geometrías y la uniformidad de la versión activa requieren pruebas de datos. No quedan garantizadas solo por dibujar las relaciones o declarar claves en tablas estándar de Snowflake.

## Código DBML para dbdiagram.io

Copiar todo el contenido del siguiente bloque en el editor de [dbdiagram.io](https://dbdiagram.io/). Es el modelo completo, no solo las tablas postales. En DBML, `>` representa una relación muchos-a-uno. Las reglas de coherencia postal descritas arriba se validarán con pruebas; las notas DBML no las ejecutan.

```dbml
Project Civica_Silver {
  database_type: 'Snowflake'
  Note: 'Modelos dbt de Silver. Las relaciones son lógicas; el diagrama no acredita su despliegue en Snowflake.'
}

Table Reports {
  report_id varchar [pk]
  report_number varchar [not null, unique]
  report_date_time timestamp_ntz
}

Table Crimes {
  offense_id varchar [not null, note: 'Identificador de origen. Aún admite variantes de un mismo ID.']
  report_id varchar
  offense_date timestamp_ntz
  nibrs_key varchar
  offense_category_id varchar
  offense_subcategory_id varchar
  address_id varchar
  police_area_id varchar
}

Table Offense_categories {
  offense_category_id varchar [pk, not null]
  offense_category varchar [not null, unique]
}

Table Offense_subcategories {
  offense_subcategory_id varchar [pk, not null]
  offense_category_id varchar
  offense_sub_category varchar [not null]

  indexes {
    (offense_category_id, offense_sub_category) [unique]
  }
}

Table Arrest {
  arrest_number varchar [pk]
  last_ingested_at timestamp_ltz [not null]
  source_version_count number [not null]
  source_signature varchar [not null]
  max_completeness_score number [not null]
  consolidation_conflicts object [not null]
  consolidation_choices object [not null]
  arrest_occurred_date_time timestamp_ntz
  arrest_reported_date_time timestamp_ntz
  report_id varchar
  arrest_type_id varchar
  agent_key varchar
  subject_key varchar
  address_id varchar [not null]
  police_area_id varchar
  crisis_involved boolean
  complaint_involved boolean
  force_involved boolean
  terry_stop boolean
  demonstration boolean
  subgect_age_at_detention varchar
  agents_age_at_detention number(38,0)
  cad_profile_id varchar
}

Table Cad_profiles {
  cad_profile_id varchar [pk, not null]
  cad_clearance varchar
  cad_initial_call_type varchar
  cad_priority number(38,0)
}

Table Arrest_conflicts {
  arrest_number varchar [not null]
  field_name varchar [not null]
  observed_values variant
  selected_value variant
  max_completeness_score number
  last_ingested_at timestamp_ltz

  indexes {
    (arrest_number, field_name) [pk]
  }

  Note: 'Vista de auditoría: una fila por detención y campo en conflicto.'
}

Table Crime_shooting_types {
  offense_id varchar [not null]
  shooting_type_id varchar [not null]

  indexes {
    (offense_id, shooting_type_id) [pk]
  }
}

Table Shooting_types {
  shooting_type_id varchar [pk]
  description varchar [not null, unique]
}

Table NIBRS {
  nibrs_key varchar [pk]
  offense_code varchar [not null, unique]
  offense_description varchar
  group_ab varchar
  crime_against_category varchar
}

Table Arrest_offenses {
  arrest_offense_id varchar [pk]
  arrest_number varchar [not null]
  offense_type_id varchar
  nibrs_description varchar
}

Table Offense_types {
  offense_type_id varchar [pk]
  offense_type varchar [not null, unique]
}

Table Arrest_types {
  arrest_type_id varchar [pk]
  description varchar [not null, unique]
}

Table Agents {
  agent_key varchar [pk]
  officer_id varchar [not null]
  officer_gender varchar
  officer_race varchar
  squad_description varchar
  officer_title varchar
}

Table Subject {
  subject_key varchar [pk]
  sk_person varchar [not null]
  subject_gender varchar
  subject_race varchar
}

Table Full_address {
  address_id varchar [pk]
  block_address varchar
  latitude number(18,5)
  longitude number(18,5)
  neighborhood varchar
  reporting_area varchar
  census_block_2020 varchar
  cp varchar [note: 'CP opcional. No contiene mensajes ni motivos: solo se informa con cp_status = matched.']
  cp_status varchar [not null, note: 'matched, missing_coordinates, redacted, invalid_coordinates, no_match, ambiguous, boundary. CP no nulo si y solo si el estado es matched.']

  Note: 'Ubicación publicada normalizada. Conserva el CP y su estado, sin tabla adicional ni histórico de evaluaciones. address_id no depende del CP, del estado ni de la versión del mapa.'
}

Table Police_Add {
  police_area_id varchar [pk]
  precinct varchar
  sector varchar
  beat varchar
}

Table Postal_codes {
  cp varchar [pk]
  geography geography [note: 'Polygon o MultiPolygon en EPSG:4326. Unión de las piezas del CP. Nulo si no hay geometría disponible.']
  boundary_version varchar [note: 'Versión de la geometría activa. Nula si geography es nula. No es una FK ni una clave única.']

  Note: 'Una fila por CP. Sustituye Address_cp y los polígonos por pieza del diseño anterior. Una única versión activa para todas las geometrías no nulas; admite CP de licencias sin polígono local.'
}

Table Licencia {
  license_id varchar [not null, unique]
  license_number varchar [pk]
  license_issue_date date
  animal_name varchar
  species varchar
  primary_breed varchar
  secondary_breed varchar
  cp varchar [note: 'Procede del ZIP Code del origen de licencias, no del cruce espacial policial.']
}

Ref: Crimes.report_id > Reports.report_id
Ref: Arrest.report_id > Reports.report_id
Ref: Crimes.nibrs_key > NIBRS.nibrs_key
Ref: Crimes.address_id > Full_address.address_id
Ref: Crimes.police_area_id > Police_Add.police_area_id
Ref: Crime_shooting_types.offense_id > Crimes.offense_id
Ref: Crime_shooting_types.shooting_type_id > Shooting_types.shooting_type_id
Ref: Arrest_offenses.arrest_number > Arrest.arrest_number
Ref: Arrest_offenses.offense_type_id > Offense_types.offense_type_id
Ref: Arrest.arrest_type_id > Arrest_types.arrest_type_id
Ref: Arrest.agent_key > Agents.agent_key
Ref: Arrest.subject_key > Subject.subject_key
Ref: Arrest.address_id > Full_address.address_id
Ref: Arrest.police_area_id > Police_Add.police_area_id
Ref: Full_address.cp > Postal_codes.cp
Ref: Licencia.cp > Postal_codes.cp
Ref: Crimes.offense_category_id > Offense_categories.offense_category_id
Ref: Crimes.offense_subcategory_id > Offense_subcategories.offense_subcategory_id
Ref: Offense_subcategories.offense_category_id > Offense_categories.offense_category_id
Ref: Arrest.cad_profile_id > Cad_profiles.cad_profile_id
Ref: Arrest_conflicts.arrest_number > Arrest.arrest_number
```
