# Marts de delitos de Seattle

## Mapa de delitos por calle

[`mart_crimes_socioeconomic`](../models/gold/marts/mart_crimes_socioeconomic.sql) contiene una fila por delito con dirección de bloque publicada y coordenadas válidas. Permite filtrar por fecha del hecho, categoría y subcategoría de Seattle o código y descripción NIBRS. Para dibujarlo se puede usar `point_geography` o el par `latitude`, `longitude`. Varios delitos pueden compartir punto: `crime_id` identifica cada uno.

`block_address` representa el bloque aproximado, no el número de portal. Se excluyen ubicaciones ocultas, sin dirección o sin coordenadas utilizables. La falta de clasificación, barrio o CP no impide mostrar el punto.

Para filtrar el mapa por las 15 categorías del proyecto, usa `nibrs_category`. El propio mart asigna los 64 códigos del catálogo a sus categorías a partir de `dim_nibrs.offense_code`. Si falta el código o aparece uno nuevo, el punto figura como `Sin clasificar`. El código y su descripción siguen disponibles para filtrar con más detalle.

### Filtros socioeconómicos

El mart incorpora el mismo contexto ACS por CP que [`mart_arrest_socioeconomic`](mart_arrest_socioeconomic.md):

- `income_quintile` (1–5) e `income_level` (`muy bajo`, `bajo`, `medio`, `alto`, `muy alto`).
- `median_household_income`, `median_home_value` y `median_monthly_rent`, para filtrar por renta anual del hogar, valor de vivienda o alquiler mensual en USD.
- `population`, `income_margin_of_error`, `zcta_name` y `has_socioeconomic_data`, para consultar el contexto y su disponibilidad.

Los quintiles se calculan sobre el catálogo postal con polígono y renta válida no censurada, una vez por CP, incluidas zonas sin delitos. Se ordenan por renta y CP antes de unir los hechos: coinciden con los de detenciones y no cambian al filtrar calles, fechas o categorías.

Se conservan todos los delitos que ya cumplían los requisitos del mapa, incluso sin CP o ACS; sus campos económicos quedan NULL y `has_socioeconomic_data = false`. Las medianas censuradas también quedan NULL, con sus indicadores `*_top_coded` y límites `*_lower_bound` (renta > 250000 USD, vivienda > 2000000 USD y alquiler > 3500 USD/mes). `has_postal_reference` indica si existe el CP en el catálogo; `geography` y `boundary_version` aportan la cartografía postal sin sustituir el punto del delito.

`acs_year = 2024` y `acs_period = '2020–2024'` describen un contexto fijo, no la economía de cada año del delito. ZIP y ZCTA se corresponden por código como aproximación. La renta es la de la zona, no la de las personas implicadas; población y medianas se repiten por delito y no deben sumarse.

Con las dependencias Gold ya construidas y el perfil DEV configurado, construye ambos
marts socioeconómicos juntos si aún no están publicados:

```bash
DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD \
  dbt build --target dev --select mart_crimes_socioeconomic mart_arrest_socioeconomic
```

Las [pruebas nativas de dbt](../models/gold/marts/_marts.yml) incluyen unicidad de `crime_id`
y no nulos de los campos obligatorios. El [test de cobertura](../tests/singular/gold/gold_marts_coverage.sql)
comprueba que ambos marts socioeconómicos conserven los identificadores y las fechas de ingesta de los hechos de Gold que les corresponden.

## Delitos y licencias por código postal

[`mart_crimes_pet_licenses`](../models/gold/marts/mart_crimes_pet_licenses.sql), en `DBT_GOLD.MARTS`, es una vista con una fila por `(cp, year)`: reúne los tres indicadores y una sola copia de las licencias, sus proporciones y la cartografía.

La vista calcula los totales a partir de las fuentes vigentes cada vez que se consulta. Si se corrige el año de un delito en `fact_crimes` de 2024 a 2025, deja de contar en 2024 y pasa a contar en 2025, sin volver a ejecutar el mart. Si 2024 deja de tener delitos o licencias, deja de aparecer. La versión incremental anterior se conserva [como referencia](mart_crimes_pet_licenses.txt).

| Indicador | Delitos incluidos |
|---|---|
| `vehicle_theft_count` | Robo de vehículos de motor (`240`). No incluye la sustracción de objetos del interior ni de piezas del vehículo. |
| `theft_count` | Suma de atracos (`120`), carterismos (`23A`), tirones de bolso (`23B`) y otros hurtos (`23H`). |
| `shooting_or_homicide_count` | Cualquier delito con etiqueta de tiroteo observada o clasificado como homicidio (`09A`, `09B`, `09C`). |

Para el segundo caso se eligió **un solo total de los cuatro códigos** del [catálogo NIBRS de referencia](../datos_ejemplo/Todos_los_crimenes.csv). No se filtra por `crime_against_category`: esa columna clasifica el delito, no identifica a su víctima. El `120` puede incluir atracos en comercios y el `23H` no exige sustracción directa a una persona. Por eso `theft_count` no debe rotularse como «robos a personas» ni como total de todos los delitos patrimoniales. Las agresiones sin robo quedan fuera.

## Cómo se obtiene una fila

En `shooting_or_homicide_count` entran todos los asesinatos y homicidios no negligentes (`09A`), los homicidios negligentes (`09B`) y los justificados (`09C`), con o sin tiroteo. También entra cualquier otro delito con etiqueta en `bridge_crime_shooting_types`, incluso si falta el código NIBRS. Cada `crime_id` cuenta una sola vez en este indicador, aunque cumpla ambos criterios o tenga varias etiquetas. El puente se deduplica por `crime_id` antes de unirlo al hecho.

1. Se toman los años naturales con al menos una ocurrencia de `fact_crimes`, consultando `dim_date` por `offense_date_key`, y una `license_issue_date` en `dim_licenses`. La coincidencia se calcula para el conjunto de las fuentes, antes de filtrar por delito o especie; un año parcial también entra.
2. Se cruzan esos años con todos los CP de `dim_postal_codes`. Los tres indicadores se calculan en una sola agregación de delitos por fecha del hecho y CP de `dim_address`. Las licencias se agregan aparte por fecha de emisión y CP declarado. Los registros sin fecha o sin CP no aportan a los recuentos. Unir los totales después de agrupar evita multiplicar delitos por licencias.
3. Si un CP no tiene casos registrados en un año común, su recuento es **cero**. Esto permite comparar también las zonas con pocos casos. Un cero no garantiza cobertura policial en ese CP, y un año común no implica doce meses completos en ambas fuentes.

## Licencias y cartografía

| Columnas comunes | Interpretación |
|---|---|
| `dog_license_count`, `cat_license_count`, `goat_license_count`, `pig_license_count` | Licencias emitidas de perro, gato, cabra y cerdo. Se usa `dim_licenses.species` porque `species_group` agrupa cabras y cerdos en `other`. |
| `pet_license_count` | Suma de las cuatro especies. No hay columnas para otras especies o especies desconocidas. Se cuentan números de licencia, no animales únicos ni licencias vigentes. |
| `cumulative_dog_license_count`, `cumulative_cat_license_count`, `cumulative_goat_license_count`, `cumulative_pig_license_count` | Emisiones de cada especie hasta el año de la fila inclusive, incluso en años anteriores sin delitos. Son saldos acumulados: no sumarlos entre años. |
| `dog_license_share`, `cat_license_share`, `goat_license_share`, `pig_license_share` | Recuento de la especie dividido por `pet_license_count`: fracción de 0 a 1, o `NULL` si no se emitieron licencias. |
| `geography`, `boundary_version` | Polígono y versión del mapa activo. Un CP sin polígono se conserva en la vista, aunque no pueda dibujarse en el mapa. |

Los recuentos son absolutos, no tasas por habitante o vehículo. No se deben sumar los tres indicadores como si fueran excluyentes: un atraco con tiroteo suma en `theft_count` y `shooting_or_homicide_count`. Las licencias no se repiten por indicador. Una asociación entre zonas no vincula un animal con un delito concreto.

## Estado y ejecución en DEV

Se comprobó con datos sintéticos que el nuevo SQL reproduce las columnas de los tres modelos anteriores, incluidos ceros, licencias y cartografía. **Queda pendiente validar el build con datos reales en Snowflake DEV.**

Con Gold ya construido y el perfil DEV configurado según la [guía de Gold](gold.md), el siguiente paso es:

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt build --target dev --select mart_crimes_pet_licenses
```

Este comando publica la vista y ejecuta las comprobaciones de columnas. No añadir `+` si las dependencias ya están actualizadas.

Con los tres marts publicados, `dbt test --target dev --select gold_marts_coverage` ejecuta el test de cobertura de Gold a los marts. Para la vista comprueba una fila por CP y año común, y contrasta los recuentos anuales de delitos y licencias con Gold. No vuelve a validar los acumulados ni las proporciones.

### Migración

Si `MART_CRIMES_PET_LICENSES` ya existe como tabla en DEV, revisa el respaldo, los consumidores y sus permisos antes de sustituirla. Con autorización, ejecuta una vez `dbt build --target dev --full-refresh --select mart_crimes_pet_licenses`: el adaptador Snowflake retira la tabla homónima y crea la vista. Vuelve a dar `SELECT ON VIEW` a los roles de lectura. Si el objeto no existe o ya es una vista, no necesitas `--full-refresh`.

La primera pestaña del panel mantiene el mismo nombre de objeto, los tres indicadores, la cartografía y el filtro de 50 licencias. El periodo visible es 2024–2026 y el año inicial es 2024. La vista conserva todos los años comunes y los acumulados incluyen emisiones anteriores a 2024.

## Carga incremental

Los dos marts socioeconómicos detectan ingestas nuevas con `after_max_ingested_at`. El de delitos reemplaza los delitos del lote; el de arrestos recalcula los grupos CP-año afectados con todos sus arrestos.

Si los marts socioeconómicos ya existen con el esquema anterior, el primer despliegue requiere una reconstrucción. Usa también `--full-refresh` si hay borrados, cambios en dimensiones sin una nueva ingesta del hecho o ubicaciones que deban dejar de publicarse. El corte tampoco recupera ingestas con una marca igual o anterior a la última publicada.

```bash
dbt build --target dev --full-refresh --select mart_crimes_socioeconomic mart_arrest_socioeconomic
```
