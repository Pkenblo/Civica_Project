# Modelo definitivo de Silver: diccionario y DBML

El [diagrama SVG](silver_diagram.svg) y el diccionario DBML de esta página representan los mismos **17 modelos, 96 columnas y 19 relaciones lógicas** de `models/silver/`. Para los granos, decisiones de diseño y operación, véase la [guía de Silver](silver.md). La referencia describe lo que publica dbt, no certifica un despliegue en Snowflake.

## Cómo leer las relaciones

- `PK` identifica una fila del modelo, `UK` una clave alternativa y `FK` una referencia lógica. En el SVG las flechas apuntan a la clave padre; en DBML `>` también representa muchos-a-uno. Las referencias admiten nulos salvo donde se indica `not null`. Las claves se verifican con pruebas de datos, no mediante restricciones físicas impuestas por el diagrama.
- `reports` es padre de `crimes` y `arrest`; no hay una FK entre ambos hechos. `crime_shooting_types` usa `crime_id`, no `offense_id`. `arrest_offenses` referencia la detención y no tiene una FK a NIBRS: conserva la descripción de origen, no un código inferido.
- `full_address` y `police_add` sirven a ambos hechos policiales. `postal_codes` es padre de `full_address` y `licenses` por `cp`. El cruce punto–polígono calcula el CP de una ubicación; no es una relación adicional. El CP de una licencia no pasa por una ubicación policial.

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
  offense_subcategory_id varchar
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
  offense_description varchar
  group_ab varchar
  crime_against_category varchar [note: 'Categoría propia de NIBRS, independiente de la de Seattle.']
}

Table offense_categories {
  offense_category_id varchar [pk]
  offense_category varchar [not null, unique]
}

Table offense_subcategories {
  offense_subcategory_id varchar [pk]
  offense_category_id varchar
  offense_sub_category varchar [not null, note: 'La etiqueta se identifica en el contexto de la categoría, incluso si falta el padre.']
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

  Note: 'Incremental delete+insert: última fila completa por número, incluidos sus nulos.'
}

Table arrest_offenses {
  arrest_offense_id varchar [pk]
  arrest_number varchar [not null]
  offense_type varchar [note: 'Texto legal, sin catálogo de tipos de infracción.']
  nibrs_description varchar [note: 'Texto publicado en el origen de detenciones, sin inferir un código NIBRS.']

  indexes {
    (arrest_number, offense_type, nibrs_description) [unique]
  }
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
  squad_description varchar
  officer_title varchar
  ingested_at timestamp_ltz

  Note: 'Último perfil observado por officer_id; sin vigencias históricas.'
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
  address_id varchar [pk, note: 'Independiente del CP, su estado y la versión del mapa.']
  block_address varchar [note: 'Dirección aproximada a nivel de bloque.']
  latitude number(18,5)
  longitude number(18,5)
  neighborhood varchar
  reporting_area varchar
  census_block_2020 varchar
  is_location_redacted boolean
  has_missing_coordinates boolean
  has_invalid_coordinates boolean
  location_context varchar [note: 'Origen y clave del evento si no se dispone de un punto utilizable y la clave está informada.']
  cp_status varchar [not null, note: 'matched, redacted, missing_coordinates, invalid_coordinates, no_match, ambiguous o boundary.']
  cp varchar [note: 'No nulo solo cuando cp_status = matched.']
}

Table police_add {
  police_area_id varchar [pk]
  precinct varchar [note: 'Distrito policial.']
  sector varchar
  beat varchar [note: 'Zona de patrulla; no se presupone única fuera de la combinación de área.']
}

Table postal_codes {
  cp varchar [pk]
  geography geography [note: 'Unión de piezas del CP (Polygon o MultiPolygon en EPSG:4326); nula si no hay polígono local.']
  boundary_version varchar [note: 'Versión activa; nula si no hay polígono. No es una clave foránea ni única.']
}

Table licenses {
  license_id varchar [not null, unique, note: 'Identificador alternativo derivado del número y el nombre del animal.']
  license_number varchar [pk]
  license_issue_date date
  animal_name varchar
  species varchar
  primary_breed varchar
  secondary_breed varchar
  cp varchar [note: 'ZIP de origen si tiene cinco dígitos; nunca un CP inferido por cruce espacial.']
  ingested_at timestamp_ltz [not null]

  Note: 'Incremental delete+insert: última versión por número de licencia.'
}

Ref: crimes.report_id > reports.report_id
Ref: crimes.nibrs_key > nibrs.nibrs_key
Ref: crimes.offense_category_id > offense_categories.offense_category_id
Ref: crimes.offense_subcategory_id > offense_subcategories.offense_subcategory_id
Ref: crimes.address_id > full_address.address_id
Ref: crimes.police_area_id > police_add.police_area_id
Ref: offense_subcategories.offense_category_id > offense_categories.offense_category_id
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
Ref: full_address.cp > postal_codes.cp
Ref: licenses.cp > postal_codes.cp
```
