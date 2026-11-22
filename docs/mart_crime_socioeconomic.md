# Criminalidad y contexto socioeconómico por zona

## Modelo y dependencias comprobadas

[`mart_crime_socioeconomic`](../models/gold/marts/mart_crime_socioeconomic.sql)
es una tabla en `DBT_GOLD.GOLD`, según la configuración vigente de `models/gold/`.
Sigue la ubicación y materialización de los marts actuales en `models/gold/marts/`;
no utiliza la configuración antigua de `models/marts/` ni cambia `dbt_project.yml`.

Utiliza únicamente estas dependencias Gold mediante `ref()`:

| Modelo | Uso y cardinalidad necesaria |
| --- | --- |
| `fact_crimes` | Una fila por `crime_id`, con `crime_count = 1`. Silver deriva esa clave de `(report_id, offense_id)`; un informe puede contener varios delitos legítimos. |
| `dim_address` | Una ubicación por `address_id`; proporciona `cp` y `cp_status`. |
| `dim_postal_codes` | Un registro por `cp`, con `geography` y `boundary_version`. |
| `dim_offense_classification` | Una fila por `offense_classification_id`, que identifica una pareja categoría–subcategoría de Seattle. |
| `dim_census_socioeconomic` | Una fila por `cp` ZCTA. Es **ephemeral**: dbt inserta su SQL y lee el Silver existente; no reconstruye Silver. |

También se revisaron `dim_nibrs`, los cuatro marts actuales, los contratos YAML
de Gold y el SQL Silver que fija los granos y asigna los CP. NIBRS es una
clasificación independiente y no se exige para incluir un delito. No se utilizan
puentes de tiroteos, detenciones ni licencias, que podrían multiplicar los hechos.

## Grano y recuentos

**Una fila por `(cp, year, offense_classification_id)`**, es decir, CP × año del
hecho × categoría y subcategoría de Seattle. Se conserva la subcategoría porque
el nivel de categoría por sí solo no permite distinguir robos, hurtos o agresiones.
No se introduce otra clasificación: las claves y etiquetas son las de Gold.

Se cruzan todos los CP del catálogo con los años presentes en `offense_date` y
las clasificaciones existentes, más una clasificación de clave NULL. Así se
conservan ceros y CP sin ACS. La clave NULL recoge los delitos sin clasificación;
no es una nueva clave del catálogo. Las clasificaciones parciales existentes
(categoría sin subcategoría, o viceversa) mantienen su clave Gold.

Cada `crime_id` elegible se cuenta una sola vez. No se colapsan todos los delitos
de un informe en un incidente, ni se usa `COUNT(DISTINCT)` para ocultar problemas
de JOIN en el modelo. Las pruebas detectan claves duplicadas de entrada,
clasificaciones huérfanas y diferencias frente al recuento independiente por delito.

Quedan fuera del recuento los hechos sin dirección/CP asignado, los CP que no
existen en el catálogo y los hechos sin `offense_date`. El diagnóstico separa
estos motivos en grupos excluyentes; la falta de clasificación o de ACS **no**
excluye un delito con CP y fecha utilizables. Si no hay ninguna fecha de delito,
no hay años que expandir y el mart queda vacío.

## Geografía, ACS y quintiles

El camino es `fact_crimes.address_id → dim_address.address_id → dim_address.cp
→ dim_postal_codes.cp = dim_census_socioeconomic.cp`. El CP de la dirección ya
resulta de una coincidencia interior única punto–polígono en Silver. No se
recalcula por cercanía, por nombre de calle ni a partir del bloque censal.
`geography` y `boundary_version` se proyectan sin alterarlas.

La unión ZIP–ZCTA por código es una **aproximación aceptada**: sus límites pueden
diferir. La población es la estimación de la ZCTA completa, no la población
exacta del polígono postal ni de su parte situada dentro de Seattle.

Todas las estimaciones corresponden a **ACS 2024 5-year, periodo 2020–2024**.
La renta se expresa en USD ajustados a 2024. Asociar este contexto fijo con
delitos históricos no reconstruye la economía ni la población de cada año.
Las tasas son delitos registrados por población residencial ACS; visitantes,
desplazamientos, actividad comercial y años parciales pueden afectar su lectura.
Una asociación entre zonas no describe a las personas implicadas ni demuestra
causalidad. No existe aquí un indicador agregado nuevo de «delito violento»:
se filtran las categorías y subcategorías publicadas, sin equiparar automáticamente
todos los delitos contra personas con violencia.

El catálogo postal **no delimita el municipio de Seattle**: contiene la cartografía
activa de King County y códigos incorporados por licencias, algunos sin polígono.
Se conservan todos, igual que en los marts existentes. Un cero significa ausencia
de registros asignados, no ausencia real de delincuencia ni cobertura policial
completa. No se inventa una selección municipal sin una delimitación validada.

Los quintiles se calculan una sola vez sobre una fila por CP con polígono y renta
no negativa, disponible y no limitada superiormente. No se incluyen los ZCTA
nacionales ajenos al catálogo, los CP sin polígono ni las repeticiones por año o
clasificación. Se usa `NTILE(5)` ordenado por renta y CP: los grupos tienen tamaños
similares, pero dos zonas con idéntica renta pueden quedar separadas por el
desempate. Con menos de cinco zonas válidas no aparecen los cinco grupos.
Los quintiles son relativos a ese ámbito, no umbrales de pobreza, y no se
recalculan al aplicar filtros de una herramienta BI.

Silver ya convierte los códigos negativos especiales en NULL. El mart no repite
esa normalización: prueba que no hayan llegado valores negativos. Para los
importes limitados superiormente publica NULL en la mediana, conserva el flag
y proporciona el umbral inferior conocido: renta **> 250000 USD**, vivienda
**> 2000000 USD**, alquiler **> 3500 USD/mes**. No interpreta los marcadores
`250001`, `2000001` y `3501` como estimaciones. La renta censurada no recibe quintil.

## Columnas finales

Las descripciones y los tests dbt están en
[`_mart_crime_socioeconomic.yml`](../models/gold/marts/_mart_crime_socioeconomic.yml).

| Columnas | Significado |
| --- | --- |
| `cp`, `year` | Código postal y año natural del hecho, no de denuncia. |
| `offense_classification_id` | Clave Gold de categoría–subcategoría, o NULL para ausencia de clasificación. |
| `offense_category_id`, `offense_category` | Clave y nombre de categoría Seattle, sin recodificar. |
| `offense_subcategory_id`, `offense_sub_category` | Clave y nombre de subcategoría Seattle, sin recodificar. |
| `crime_count` | Delitos de la fila; sumar subcategorías da el número de delitos por categoría. |
| `postal_year_crime_count` | Total de delitos del CP-año, incluidos los no clasificados; repetido en cada clasificación. |
| `crimes_per_1000` | `crime_count × 1000 / NULLIF(population, 0)`. |
| `postal_year_crimes_per_1000` | Total del CP-año × 1000 / `NULLIF(population, 0)`; repetido. |
| `crime_share_pct` | Porcentaje de la clasificación sobre el total CP-año; NULL cuando el total es cero. Sumar las subcategorías da el porcentaje de la categoría. |
| `geography`, `boundary_version` | Geometría postal original y versión; pueden faltar. |
| `zcta_name`, `has_socioeconomic_data` | Nombre de la ZCTA y existencia de correspondencia por CP. El indicador no garantiza disponibilidad de todas las métricas. |
| `acs_year`, `acs_period` | Constantes `2024` y `2020–2024`. |
| `median_household_income` | Renta mediana anual por hogar, USD de 2024; NULL si ausente o censurada. |
| `income_margin_of_error` | Margen de error de renta al 90 %, USD; puede ser NULL. |
| `population` | Población estimada de la ZCTA, fija entre años y clasificaciones. |
| `median_home_value` | Valor mediano de vivienda ocupada por propietarios, USD; NULL si ausente o censurado. |
| `median_monthly_rent` | Alquiler contractual mediano mensual, USD; NULL si ausente o censurado. |
| `income_top_coded`, `home_value_top_coded`, `rent_top_coded` | Indicadores originales de límites superiores; NULL cuando no existe correspondencia ACS. |
| `income_lower_bound`, `home_value_lower_bound`, `rent_lower_bound` | Umbrales inferiores anteriores solo para valores censurados, no sustitutos de las medianas. |
| `income_quintile`, `income_level` | Quintil 1–5 y etiqueta `muy bajo`, `bajo`, `medio`, `alto`, `muy alto`; NULL fuera del ámbito válido. |

### Uso en visualización

- Para mapas, usar `geography` y filtrar año y clasificación, o agregar primero
  los recuentos al nivel deseado. Los CP sin geometría siguen disponibles en tablas.
- Solo `crime_count` es un recuento aditivo entre todas las filas. Los totales
  postales se recuperan con `MAX` por CP-año, no con `SUM` entre clasificaciones.
- Población y medianas no se suman entre clasificaciones ni años. Antes de combinar
  zonas, deduplicar población por CP y no sumar ni promediar medianas como si
  resultara una mediana conjunta. Las tasas de varias zonas se recalculan a
  partir de los recuentos y denominadores únicos apropiados, no sumando tasas.
- Para correlaciones, elegir primero un año y una categoría/subcategoría, o
  agregar los delitos por CP. No tratar las repeticiones de una misma zona como
  observaciones económicas independientes.
- Para el porcentaje de una categoría, sumar `crime_share_pct` entre sus
  subcategorías dentro del mismo CP-año; el denominador incluye todas las
  categorías, incluso la clasificación ausente.

## Construcción y validación acotadas

Con un perfil externo autenticado, permiso para crear la tabla y las dependencias
ya construidas, desde la raíz del repositorio:

```bash
DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD \
  dbt build --target dev --select mart_crime_socioeconomic
```

No añadir `+`: reconstruiría dependencias. La selección incluye únicamente el
nuevo modelo y sus 19 tests de datos (14 YAML y cinco singulares), no los tests
propios de las capas existentes. Para solo materializar, usar `dbt run` con la
misma selección; para repetir solo sus pruebas, `dbt test` con esa selección.

El informe de lectura está en
[`analyses/mart_crime_socioeconomic_validation.sql`](../analyses/mart_crime_socioeconomic_validation.sql):

```bash
DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD \
  dbt show --target dev --select mart_crime_socioeconomic_validation --limit 1
```

Devuelve los delitos originales y representados, cobertura geográfica y ACS
(respecto a todos los hechos y respecto a los elegibles), CP representados y sin
ACS, exclusiones por localización y por otros motivos, claves de clasificación
inválidas, grupos duplicados, filas adicionales tras los JOIN y diferencia de
reconciliación. La cobertura ACS significa correspondencia de código; se informa
también de cobertura con renta numérica no censurada. Si hay duplicados en las
entradas, corregirlos con autorización antes de interpretar las coberturas.

Los cinco tests singulares comprueban:

1. Claves de entrada únicas/no nulas necesarias para los JOIN, `crime_count = 1`,
   clasificación referenciada, CP asignados como `matched`, valores económicos
   no negativos y coherencia de flags de censura.
2. Reconciliación por CP-año-clasificación contra `COUNT(DISTINCT crime_id)`
   elegible, independientemente del JOIN económico y de clasificación.
3. Totales, tasas y porcentajes con denominadores nulos/cero y tolerancia `0.000001`.
4. Fidelidad de claves, nombres, geometría, indicadores ACS y quintiles.
5. Presencia de todas las combinaciones esperadas, incluidas las de cero delitos.

### Resultados de esta entrega

**No se ha construido la tabla ni medido la cobertura real en Snowflake.** Falta
`~/.dbt/profiles.yml`; la conexión local `civica` solicita autenticación por
contraseña y no tiene contraseña disponible. No se han cambiado credenciales,
perfiles ni permisos.

Se ejecutaron `dbt parse`, `dbt ls` y compilación acotada del modelo, sus tests
y el diagnóstico, sin introspección ni conexión, sobre una copia temporal del
proyecto y un perfil ficticio. La selección contiene un modelo y 19 tests nuevos.
La advertencia de dbt sobre `models.my_new_project.marts` sin recursos corresponde
a la configuración antigua del proyecto; no se corrigió.

La regresión local se ejecuta con:

```bash
python tests/integration/mart_crime_socioeconomic_check.py
```

Usa el SQL real del modelo y de los cinco tests singulares, traducido de Snowflake
a SQLite mediante `sqlglot`, y comprueba además las 14 declaraciones YAML. Es una
comprobación **sintética**, no una ejecución del motor Snowflake ni una validación
espacial: las geometrías de prueba son etiquetas. Resultado del fixture:

| Comprobación sintética | Resultado |
| --- | --- |
| Delitos originales / elegibles / representados | 15 / 10 / 10 |
| Excluidos sin localización / CP ajeno al catálogo / sin fecha | 3 / 1 / 1 |
| Cobertura geográfica | 11/15 = 73,33 % |
| Correspondencia ACS sobre originales / elegibles | 10/15 = 66,67 % / 9/10 = 90 % |
| CP representados / sin ACS | 14 / 1 |
| Filas del mart | 140 = 14 CP × 2 años × 5 clasificaciones, incluida NULL |
| Grupos duplicados / filas extra en JOIN / diferencia de reconciliación | 0 / 0 / 0 |
| Pruebas YAML / singulares | 14 / 5, sin fallos |
| Controles negativos | Detectan ACS duplicado, tasa incorrecta, categoría alterada y combinación omitida. |

También se comprobaron conservación de delitos sin categoría, clasificaciones
parciales, población cero, CP sin ACS o sin polígono, censura de los tres importes
y quintiles sobre zonas únicas antes de expandir por años y clasificaciones.
**Estos porcentajes no describen los datos reales del proyecto.** Las cifras reales
y la ejecución de los tests en Snowflake quedan pendientes de autenticación.
