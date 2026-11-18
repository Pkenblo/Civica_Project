# Civica Project

Proyecto dbt sobre Snowflake con delitos, arrestos y licencias de mascotas de Seattle. Su conexión por CP es únicamente geográfica.

## Estado y referencias

- Bronze, tres modelos de staging y macros existentes. Silver y el enriquecimiento postal todavía no están implementados.
- Modelo: **15 tablas, 82 columnas y 16 relaciones 1:N**. [Diccionario y DBML completo](silver_diagram.md) · [Diagrama SVG](Silver_Diagram_actualizado.svg).
- Este README recoge las decisiones posteriores al diagrama; `fallos.md` y `docs/codigo_postal.md` conservan propuestas antiguas.

## Preparación de los datos

Staging limpia nombres, marcadores y tipos, **sin eliminar duplicados ni asociaciones**. La deduplicación corresponde a Silver para no perder información antes de interpretarla.

Los modelos leen `RAW` y generan vistas en `STG` de `{{ target.name | upper }}_BRONZE`. Se conservan metadatos de carga y `is_location_redacted` para distinguir procedencia, ocultación y ausencia.

## Revisión de los problemas

### 1. Grano: validado con los CSV

| Conjunto | Filas | Identificadores distintos | Repeticiones encontradas |
| --- | ---: | ---: | --- |
| Crimes | 1.575.312 | 1.575.310 | Dos delitos con distintos tipos de tiroteo. |
| Arrests | 145.625 | 110.143 | 25.352 arrestos con distintas infracciones. |
| Licencias | 38.413 | 38.410 | Tres duplicados exactos. |

No hay atributos propios contradictorios ni versiones que seleccionar. Se mantiene una fila por entidad y sus asociaciones en `Crime_shooting_types` y `Arrest_offenses`, extraídas antes de deduplicar. `nibrs_description` permanece en las infracciones: un arresto tiene dos descripciones distintas.

### 2. Temporalidad: aplazada

La historización de agentes y sujetos se consultará con los profesores; no se considera resuelta.

### 3. Código postal: solución acordada

Se usarán coordenadas y polígonos de [King County](https://www5.kingcounty.gov/sdc/?Layer=zipcode_area): las direcciones son aproximadas y una calle puede atravesar varios CP. La prueba exploratoria encontró una zona única para el 74,41 % de las filas de delitos y el 98,34 % de arrestos, sin garantizar precisión postal.

- `Postal_codes` sustituye a `Address_cp`: una fila por CP, piezas unidas en `geography` y una sola cartografía activa identificada por `boundary_version`.
- `Full_address` conserva `cp` y `cp_status`; se descartó la tabla adicional de evaluación por innecesaria. Solo `matched` permite CP no nulo: los motivos no se mezclan con códigos.
- Las licencias apuntan directamente al catálogo con su CP de origen, aunque no tenga geometría local. No se imputa el CP más cercano ni se reconstruyen ubicaciones ocultadas.

Se exportará la cartografía a EPSG:4326 para el cruce espacial, conservando `decimal(18,12)`. No se guardará histórico de evaluaciones: el mapa actual no acredita límites antiguos y sus cambios exigirán recalcular asignaciones.

### 4. Sujetos sin identificador: regla acordada

Hay **71 arrestos con `Subject ID = -1`**, sin datos demográficos útiles ni motivo de ausencia informado.

- Staging ya convierte `-1` o vacío en `subject_id = NULL`, conservando el arresto.
- `Subject` solo tendrá sujetos identificados; `sk_person` seguirá siendo obligatorio.
- Sin identificador, `Arrest.subject_key = NULL`; la FK ya lo permite. No se crean sujetos ficticios ni un `subject_status` sin motivo conocido.
- Si existe identificador pero falta el sujeto correspondiente, es un error de integridad, no un desconocido.

La estructura ya es compatible; la regla se aplicará al implementar Silver.

### 5. Trazabilidad

Staging conserva metadatos de carga; su propagación a Silver queda pendiente de implementación.

## Entorno y siguiente paso

dbt Core local evita necesitar una cuenta de dbt Cloud. Instalado sin `venv`: Python 3.14.8, Core 1.12.7 y `dbt-snowflake` 1.12.5. VS Code usa `jinja-sql`, Power User y sqlfmt sin formateo automático.

Con el perfil `default` configurado fuera del repositorio en `~/.dbt/profiles.yml`:

```bash
dbt debug
dbt deps
dbt parse
dbt run --select stg_pet_licenses stg_crimes stg_arrests
dbt test --select stg_pet_licenses stg_crimes stg_arrests
```

Siguiente paso: implementar Silver y pruebas de unicidad, integridad y coherencia postal. La validación local de estos CSV no garantiza futuras cargas ni una ejecución en Snowflake.
