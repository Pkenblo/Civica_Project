# Robos y licencias de mascotas por código postal

Los dos marts de `DBT_GOLD.MARTS` preparan los datos para comparar zonas de Seattle por año. Cada tabla tiene una fila por `(cp, year)` y un solo indicador de delitos. Las gráficas y el cálculo de correlaciones quedan para el análisis posterior.

| Modelo | Indicador | Delitos incluidos (NIBRS) |
|---|---|---|
| [`mart_vehicle_theft_pet_licenses`](../models/marts/mart_vehicle_theft_pet_licenses.sql) | `vehicle_theft_count` | Robo de vehículos de motor (`240`). No incluye la sustracción de objetos del interior ni de piezas del vehículo. |
| [`mart_theft_pet_licenses`](../models/marts/mart_theft_pet_licenses.sql) | `theft_count` | Suma de atracos (`120`), carterismos (`23A`), tirones de bolso (`23B`) y otros hurtos (`23H`). |

Para el segundo caso se eligió **un solo total de los cuatro códigos** del [catálogo NIBRS de referencia](../datos_ejemplo/Todos_los_crimenes.csv). No se filtra por `crime_against_category`: esa columna clasifica el delito, no identifica a su víctima. El `120` puede incluir atracos en comercios y el `23H` no exige sustracción directa a una persona. Por eso `theft_count` no debe rotularse como «robos a personas» ni como total de todos los delitos patrimoniales. Las agresiones sin robo quedan fuera.

## Cómo se obtiene una fila

1. Se toman los años naturales con al menos una `offense_date` en `fact_crimes` y una `license_issue_date` en `dim_licenses`. La coincidencia se calcula para el conjunto de las fuentes, antes de filtrar por delito o especie; un año parcial también entra.
2. Se cruzan esos años con todos los CP de `dim_postal_codes`. Por separado, se cuentan los delitos por fecha del hecho y CP de `dim_address`, y las licencias por fecha de emisión y CP declarado. Los registros sin fecha o sin CP no aportan a los recuentos. Unir los totales después de agrupar evita multiplicar delitos por licencias.
3. Si un CP no tiene casos registrados en un año común, su recuento es **cero**. Esto permite comparar también las zonas con pocos casos. Un cero no garantiza cobertura policial en ese CP, y un año común no implica doce meses completos en ambas fuentes.

## Licencias y cartografía

| Columnas comunes | Interpretación |
|---|---|
| `dog_license_count`, `cat_license_count`, `goat_license_count`, `pig_license_count` | Licencias emitidas de perro, gato, cabra y cerdo. Se usa `dim_licenses.species` porque `species_group` agrupa cabras y cerdos en `other`. |
| `pet_license_count` | Suma de las cuatro especies. No hay columnas para otras especies o especies desconocidas. Se cuentan números de licencia, no animales únicos ni licencias vigentes. |
| `dog_license_share`, `cat_license_share`, `goat_license_share`, `pig_license_share` | Recuento de la especie dividido por `pet_license_count`: fracción de 0 a 1, o `NULL` si no se emitieron licencias. |
| `geography`, `boundary_version` | Polígono y versión del mapa activo. Un CP sin polígono se conserva en la tabla, aunque no pueda dibujarse en el mapa. |

Los recuentos son absolutos, no tasas por habitante o vehículo. Al combinar los dos marts, unir por **CP y año** y tomar las licencias de uno solo: ambos contienen los mismos totales. Una asociación entre zonas tampoco vincula un animal con un delito concreto.

## Estado y ejecución en DEV

Se comprobó la lógica localmente con datos sintéticos: selección de códigos, años comunes, recuentos, proporciones y filas con cero. **Los dos marts siguen sin probarse en dbt ni con datos reales en Snowflake.**

Con Gold ya construido y el perfil DEV configurado según la [guía de Gold](gold.md), el siguiente paso es:

```bash
export DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD
dbt build --target dev --select 'path:models/marts'
```

El comando materializa ambas tablas y ejecuta las [pruebas declaradas](../models/marts/_marts.yml), entre ellas la unicidad de `(cp, year)`. Para validar los resultados con datos reales, contrastar cada indicador con los delitos de Gold de los mismos códigos, años y CP, y comprobar que los totales de licencias coinciden entre ambos marts.
