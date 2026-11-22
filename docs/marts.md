# Marts de delitos de Seattle

## Mapa de delitos por calle

[`mart_crimes_by_street`](../models/gold/marts/mart_crimes_by_street.sql) contiene una fila por delito con dirección de bloque publicada y coordenadas válidas. Permite filtrar por fecha del hecho, categoría y subcategoría de Seattle o código y descripción NIBRS. Para dibujarlo se puede usar `point_geography` o el par `latitude`, `longitude`. Varios delitos pueden compartir punto: `crime_id` identifica cada uno.

`block_address` representa el bloque aproximado, no el número de portal. Se excluyen ubicaciones ocultas, sin dirección o sin coordenadas utilizables. La falta de clasificación, barrio o CP no impide mostrar el punto.

Para filtrar el mapa por las 15 categorías del proyecto, usa `nibrs_category`. El propio mart asigna los 64 códigos del catálogo a sus categorías a partir de `dim_nibrs.offense_code`. Si falta el código o aparece uno nuevo, el punto figura como `Sin clasificar`. El código y su descripción siguen disponibles para filtrar con más detalle.

## Delitos y licencias por código postal

[`mart_crimes_pet_licenses`](../models/gold/marts/mart_crimes_pet_licenses.sql), en `DBT_GOLD.MARTS`, sustituye los tres marts separados de robos, robos de vehículos y tiroteos/homicidios. Tiene una fila por `(cp, year)` con los tres indicadores y una sola copia de las licencias, sus proporciones y la cartografía.

| Indicador | Delitos incluidos |
|---|---|
| `vehicle_theft_count` | Robo de vehículos de motor (`240`). No incluye la sustracción de objetos del interior ni de piezas del vehículo. |
| `theft_count` | Suma de atracos (`120`), carterismos (`23A`), tirones de bolso (`23B`) y otros hurtos (`23H`). |
| `shooting_or_homicide_count` | Cualquier delito con etiqueta de tiroteo observada o clasificado como homicidio (`09A`, `09B`, `09C`). |

Para el segundo caso se eligió **un solo total de los cuatro códigos** del [catálogo NIBRS de referencia](../datos_ejemplo/Todos_los_crimenes.csv). No se filtra por `crime_against_category`: esa columna clasifica el delito, no identifica a su víctima. El `120` puede incluir atracos en comercios y el `23H` no exige sustracción directa a una persona. Por eso `theft_count` no debe rotularse como «robos a personas» ni como total de todos los delitos patrimoniales. Las agresiones sin robo quedan fuera.

## Cómo se obtiene una fila

En `shooting_or_homicide_count` entran todos los asesinatos y homicidios no negligentes (`09A`), los homicidios negligentes (`09B`) y los justificados (`09C`), con o sin tiroteo. También entra cualquier otro delito con etiqueta en `bridge_crime_shooting_types`, incluso si falta el código NIBRS. Cada `crime_id` cuenta una sola vez en este indicador, aunque cumpla ambos criterios o tenga varias etiquetas. El puente se deduplica por `crime_id` antes de unirlo al hecho.

1. Se toman los años naturales con al menos una `offense_date` en `fact_crimes` y una `license_issue_date` en `dim_licenses`. La coincidencia se calcula para el conjunto de las fuentes, antes de filtrar por delito o especie; un año parcial también entra.
2. Se cruzan esos años con todos los CP de `dim_postal_codes`. Los tres indicadores se calculan en una sola agregación de delitos por fecha del hecho y CP de `dim_address`. Las licencias se agregan aparte por fecha de emisión y CP declarado. Los registros sin fecha o sin CP no aportan a los recuentos. Unir los totales después de agrupar evita multiplicar delitos por licencias.
3. Si un CP no tiene casos registrados en un año común, su recuento es **cero**. Esto permite comparar también las zonas con pocos casos. Un cero no garantiza cobertura policial en ese CP, y un año común no implica doce meses completos en ambas fuentes.

## Licencias y cartografía

| Columnas comunes | Interpretación |
|---|---|
| `dog_license_count`, `cat_license_count`, `goat_license_count`, `pig_license_count` | Licencias emitidas de perro, gato, cabra y cerdo. Se usa `dim_licenses.species` porque `species_group` agrupa cabras y cerdos en `other`. |
| `pet_license_count` | Suma de las cuatro especies. No hay columnas para otras especies o especies desconocidas. Se cuentan números de licencia, no animales únicos ni licencias vigentes. |
| `cumulative_dog_license_count`, `cumulative_cat_license_count`, `cumulative_goat_license_count`, `cumulative_pig_license_count` | Emisiones de cada especie hasta el año de la fila inclusive, incluso en años anteriores sin delitos. Son saldos acumulados: no sumarlos entre años. |
| `dog_license_share`, `cat_license_share`, `goat_license_share`, `pig_license_share` | Recuento de la especie dividido por `pet_license_count`: fracción de 0 a 1, o `NULL` si no se emitieron licencias. |
| `geography`, `boundary_version` | Polígono y versión del mapa activo. Un CP sin polígono se conserva en la tabla, aunque no pueda dibujarse en el mapa. |

Los recuentos son absolutos, no tasas por habitante o vehículo. No se deben sumar los tres indicadores como si fueran excluyentes: un atraco con tiroteo suma en `theft_count` y `shooting_or_homicide_count`. Las licencias no se repiten por indicador. Una asociación entre zonas no vincula un animal con un delito concreto.

## Estado y ejecución en DEV

Se comprobó con datos sintéticos que el nuevo SQL reproduce las columnas de los tres modelos anteriores, incluidos ceros, licencias y cartografía. **Queda pendiente validar el build con datos reales en Snowflake DEV.**

Con Gold ya construido y el perfil DEV configurado según la [guía de Gold](gold.md), el siguiente paso es:

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt build --target dev --select mart_crimes_pet_licenses
```

Este comando solo materializa el nuevo mart y ejecuta las [pruebas declaradas](../models/gold/marts/_marts.yml) y la [reconciliación independiente](../tests/singular/gold/mart_crimes_pet_licenses_reconciliation.sql). No añadir `+`: no se necesita reconstruir las dependencias.

La regresión sintética local se ejecuta con `python3 tests/integration/mart_crimes_pet_licenses_check.py` (requiere Jinja2, sqlglot y PyYAML). Comprueba también solapamientos, varias etiquetas por delito, tiroteos sin NIBRS, especies y años fuera de la selección, y controles negativos de recuentos y proporciones. No valida geometrías reales ni sustituye Snowflake.

### Migración

Los tres modelos SQL anteriores y sus declaraciones YAML se han retirado del repositorio. dbt **no borra las tablas antiguas de Snowflake** al eliminar sus archivos. Crear el nuevo mart, dar `SELECT` a los consumidores y actualizar sus consultas antes de retirar esas tablas con autorización. La primera pestaña de la visualización consulta exclusivamente `DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES`, incluidos los acumulados y la cartografía. Conserva los tres indicadores en el selector y el filtro de 50 licencias. El periodo visible es 2024–2026 y el año inicial es 2024; la casilla de licencias acumuladas incluye también las emisiones anteriores a 2024. El modelo mantiene todos sus años comunes, no solo esos tres. Ninguna tabla antigua se ha eliminado automáticamente.
