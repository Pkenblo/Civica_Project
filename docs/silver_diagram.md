# Modelo de Silver: diccionario y DBML

El [diagrama SVG](silver_diagram.svg) y el diccionario DBML de esta página representan los mismos **18 modelos, 118 columnas y 19 referencias lógicas**, más una correspondencia parcial ZCTA–ZIP, de `models/silver/`. La referencia describe lo que publica el código dbt, no certifica un despliegue en Snowflake. La [guía de Silver](silver.md) amplía las decisiones de diseño y operación, aunque todavía contiene un inventario y decisiones anteriores a los últimos cambios del código.

## Cómo leer las relaciones

- `PK` identifica una fila del modelo, `UK` una clave alternativa y `FK` una referencia lógica. En el SVG las flechas apuntan a la clave padre; en DBML `>` también representa muchos-a-uno. Las referencias admiten nulos salvo donde se indica `not null`. Las claves se verifican con pruebas de datos, no mediante restricciones físicas impuestas por el diagrama.
- `reports` es padre de `crimes` y `arrest`; no hay una FK entre ambos hechos. `crime_shooting_types` usa `crime_id`, no `offense_id`. `arrest_offenses` referencia la detención, el texto legal de `offense_types` y, solo por coincidencia exacta y única de descripción, el catálogo `nibrs`. Las clasificaciones legal y NIBRS son independientes.
- `offense_categories` reúne categoría y subcategoría de Seattle en una sola fila y una sola FK desde `crimes`. La pareja es única; cada etiqueta puede ser nula por separado. Ya no existe `offense_subcategories`.
- `full_address` y `police_add` sirven a ambos hechos policiales. La identidad de ubicación usa seis atributos geográficos, sin contexto de evento, CP ni indicadores de calidad. Las filas abstractas `UNKNOWN` y `REDACTED` existen siempre. El cruce punto–polígono calcula el CP; no es una relación adicional.
- `postal_codes` contiene solo la cartografía activa con prefijo `981`, no incorpora los ZIP de licencias. `licenses.cp` conserva el ZIP declarado de cinco dígitos y no pasa por una ubicación policial. Su referencia a `postal_codes` está declarada en los tests, pero el SQL no garantiza cobertura para ZIP ajenos al catálogo; debe validarse con datos.
- La línea discontinua entre `census_socioeconomic.cp` y `postal_codes.cp` representa una correspondencia analítica parcial por igualdad de código, no una FK total: ZCTA y ZIP no tienen necesariamente los mismos límites. Se conservan los ZCTA sin correspondencia. Esta asociación se documenta en una nota DBML, no con `Ref`.
- `crimes`, `arrest`, `licenses` y `offense_types` son incrementales `delete+insert`. Los tres primeros aplican un corte global por ingesta; `offense_types` relee toda la evidencia e incorpora textos llegados tarde. Los otros 14 modelos son tablas; `postal_codes` y `census_socioeconomic` llevan la etiqueta `static_model`.

## DBML para dbdiagram.io

Copiar el bloque completo en [dbdiagram.io](https://dbdiagram.io/). Los nombres, tipos, claves y notas forman el diccionario de columnas. Los índices de este bloque expresan unicidad lógica; no crean índices físicos en Snowflake.

```dbml
Project Civica_Silver {
  database_type: 'Snowflake'
  Note: 'Esquema lógico de DBT_SILVER.SILVER.'
}

Table reports {
  report_id varchar [pk]
  report_number varchar [not null, unique]
  report_date_time timestamp_ntz [note: 'Solo de delitos; nula en informes exclusivos de detenciones.']
}

Table crimes {
  crime_id varchar [pk]
  report_id varchar [not null]
  offense_id varchar [not null, note: 'Identificador de origen; puede aparecer en informes distintos.']
  offense_date timestamp_ntz [note: 'Fecha y hora de ocurrencia.']
  ingested_at timestamp_ltz [not null]
  nibrs_key varchar
  offense_category_id varchar
  address_id varchar [not null]
  police_area_id varchar

  indexes {
    (report_id, offense_id) [unique]
  }
  Note: 'Incremental delete+insert: última versión por pareja informe–delito.'
}

Table nibrs {
  nibrs_key varchar [pk]
  offense_code varchar [not null, unique]
  offense_description varchar [not null, unique]
  group_ab varchar
  crime_against_category varchar [note: 'Categoría propia de NIBRS, independiente de la de Seattle.']
}

Table offense_categories {
  offense_category_id varchar [pk]
  offense_category varchar
  offense_sub_category varchar

  indexes {
    (offense_category, offense_sub_category) [unique]
  }
  Note: 'Combinación de categoría y subcategoría de Seattle, independiente de NIBRS. Admite un nivel nulo, pero no ambos. La clave se genera con los dos campos.'
}

Table crime_shooting_types {
  crime_id varchar [not null]
  shooting_type_id varchar [not null]

  indexes {
    (crime_id, shooting_type_id) [pk]
  }
}

Table shooting_types {
  shooting_type_id varchar [pk]
  description varchar [not null, unique]
}

Table arrest {
  arrest_number varchar [pk]
  ingested_at timestamp_ltz [not null]
  arrest_occurred_date_time timestamp_ntz
  arrest_reported_date_time timestamp_ntz
  report_id varchar
  arrest_type_id varchar
  agent_key varchar
  subject_key varchar
  officer_age number(38,0) [note: 'Edad del agente en la detención.']
  subject_age_range varchar [note: 'Rango de edad del sujeto en la detención.']
  address_id varchar [not null]
  police_area_id varchar
  cad_profile_id varchar
  crisis_involved boolean
  complaint_involved boolean
  force_involved boolean
  terry_stop boolean
  demonstration boolean
  officer_squad_at_arrest varchar [note: 'Unidad del agente en la fila de la detención.']
  officer_title_at_arrest varchar [note: 'Cargo del agente en la fila de la detención.']

  Note: 'Incremental delete+insert: última fila completa por número, incluidos sus nulos.'
}

Table arrest_offenses {
  arrest_offense_id varchar [pk]
  arrest_number varchar [not null]
  offense_type_id varchar
  nibrs_key varchar [note: 'Solo por coincidencia exacta y única de descripción; no se infiere desde el texto legal.']
  nibrs_match_status varchar [not null, note: 'matched, missing, ambiguous o unmatched.']
  unresolved_nibrs_description varchar [note: 'Texto conservado solo en estados ambiguous o unmatched.']

  indexes {
    (arrest_number, offense_type_id, nibrs_key, unresolved_nibrs_description) [unique]
  }
  Note: 'Asociaciones históricas observadas. Conserva el hash de la combinación original de detención, texto legal y descripción NIBRS.'
}

Table offense_types {
  offense_type_id varchar [pk, note: 'dbt_utils.generate_surrogate_key del texto legal completo normalizado, no del código ni de sus componentes.']
  offense_type varchar [not null, unique]
  offense_type_original_values array [note: 'Variantes exactas de RAW, distintas y ordenadas.']
  legal_source varchar
  legal_code varchar
  secondary_legal_source varchar
  secondary_legal_code varchar
  external_code varchar
  offense_description varchar
  offense_category varchar [note: 'Familias explícitas ASSAULT, DRUGS, FIRE o KIDNAP/IMPRISON; independiente de Seattle y NIBRS.']
  parse_status varchar [not null, note: 'parsed, administrative o review_required.']

  Note: 'Incremental delete+insert sin corte global: relee toda la evidencia. Usa ingested_at solo internamente para seleccionar la última observación por texto. Extrae componentes sin validar la vigencia jurídica ni descartar textos no interpretables.'
}

Table arrest_types {
  arrest_type_id varchar [pk]
  description varchar [not null, unique]
}

Table cad_profiles {
  cad_profile_id varchar [pk]
  cad_clearance varchar [note: 'Resultado o cierre CAD.']
  cad_initial_call_type varchar
  cad_priority number(38,0)

  Note: 'Combinación de atributos de despacho, no una llamada individual.'
}

Table agents {
  agent_key varchar [pk]
  officer_id varchar [not null, unique]
  officer_gender varchar
  officer_race varchar

  Note: 'Último perfil observado por officer_id; sin vigencias históricas ni metadatos de ingesta publicados.'
}

Table subject {
  subject_key varchar [pk]
  sk_person varchar [not null, unique, note: 'subject_id en staging.']
  subject_gender varchar
  subject_race varchar
  ingested_at timestamp_ltz

  Note: 'Último perfil observado por sk_person; sin vigencias históricas.'
}

Table full_address {
  address_id varchar [pk, note: 'Hash de seis atributos geográficos, sin contexto de evento, indicadores de calidad ni CP. UNKNOWN y REDACTED son claves abstractas estables.']
  block_address varchar [note: 'Dirección aproximada a nivel de bloque.']
  latitude number(18,5)
  longitude number(18,5)
  neighborhood varchar
  reporting_area varchar
  census_block_2020 varchar
  is_location_redacted boolean [not null]
  has_missing_coordinates boolean [not null]
  has_invalid_coordinates boolean [not null]
  cp_status varchar [not null, note: 'matched, redacted, missing_coordinates, invalid_coordinates, no_match, ambiguous o boundary.']
  cp varchar [note: 'No nulo solo cuando cp_status = matched.']

  Note: 'Ubicación compartida por bloque, coordenadas, barrio, área de reporte y bloque censal. Indicadores agregados entre observaciones. UNKNOWN y REDACTED siempre existen, sin geografía ni CP.'
}

Table police_add {
  police_area_id varchar [pk]
  precinct varchar [note: 'Distrito policial.']
  sector varchar
  beat varchar [note: 'Zona de patrulla; no se presupone única fuera de la combinación de área.']
}

Table postal_codes {
  cp varchar [pk]
  geography geography [note: 'Unión de piezas del CP (Polygon o MultiPolygon en EPSG:4326).']
  boundary_version varchar [note: 'Versión cartográfica activa. No es una clave foránea ni única.']

  Note: 'Tabla static_model. Solo CP de la cartografía activa filtrados por prefijo 981 en staging; no incorpora ZIP de licencias.'
}

Table licenses {
  license_id varchar [not null, unique, note: 'Identificador alternativo derivado del número y el nombre del animal.']
  license_number varchar [pk]
  license_issue_date date
  animal_name varchar
  species varchar
  primary_breed varchar
  secondary_breed varchar
  cp varchar [note: 'ZIP de origen si tiene cinco dígitos; nunca inferido por cruce espacial. La cobertura en postal_codes no está garantizada por el SQL.']
  ingested_at timestamp_ltz [not null]

  Note: 'Incremental delete+insert: última versión por número de licencia.'
}

Table census_socioeconomic {
  cp varchar(5) [pk, note: 'ZCTA con prefijo 981 seleccionado en staging; no equivale al límite municipal.']
  zcta_name varchar
  median_household_income number(38,0)
  income_margin_of_error number(38,0) [note: 'Margen de error al 90 % del ingreso mediano.']
  population number(38,0)
  median_home_value number(38,0)
  median_monthly_rent number(38,0)
  income_top_coded boolean [not null]
  home_value_top_coded boolean [not null]
  rent_top_coded boolean [not null]
  ingested_at timestamp_ntz [not null]
  source_file varchar
  batch_id varchar

  Note: 'ACS 2024 5-year (2020–2024). Tabla static_model: última fila por ZCTA. Correspondencia parcial cp = postal_codes.cp, sin FK total ni eliminación de códigos sin correspondencia. Las medianas no son sumables; los flags identifican marcadores superiores, no importes exactos.'
}

Ref: crimes.report_id > reports.report_id
Ref: crimes.nibrs_key > nibrs.nibrs_key
Ref: crimes.offense_category_id > offense_categories.offense_category_id
Ref: crimes.address_id > full_address.address_id
Ref: crimes.police_area_id > police_add.police_area_id
Ref: crime_shooting_types.crime_id > crimes.crime_id
Ref: crime_shooting_types.shooting_type_id > shooting_types.shooting_type_id
Ref: arrest.report_id > reports.report_id
Ref: arrest.arrest_type_id > arrest_types.arrest_type_id
Ref: arrest.agent_key > agents.agent_key
Ref: arrest.subject_key > subject.subject_key
Ref: arrest.address_id > full_address.address_id
Ref: arrest.police_area_id > police_add.police_area_id
Ref: arrest.cad_profile_id > cad_profiles.cad_profile_id
Ref: arrest_offenses.arrest_number > arrest.arrest_number
Ref: arrest_offenses.offense_type_id > offense_types.offense_type_id
Ref: arrest_offenses.nibrs_key > nibrs.nibrs_key
Ref: full_address.cp > postal_codes.cp
Ref: licenses.cp > postal_codes.cp
```
