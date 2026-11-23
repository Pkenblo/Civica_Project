# Detenciones con dirección y contexto socioeconómico

## Grano y conservación del detalle

[`mart_arrest_socioeconomic`](../models/gold/marts/mart_arrest_socioeconomic.sql)
es una tabla en `DBT_GOLD.MARTS`. Su grano es **una fila por `arrest_number`**, no
una fila por CP-año. Cada fila conserva la ubicación de su detención con la
máxima precisión disponible en Gold: dirección de bloque, latitud, longitud,
barrio, área de reporte y referencia al bloque censal. No se redondean de nuevo
las coordenadas ni se sustituyen puntos por centroides postales.

`block_address` es una dirección **aproximada por bloque**, no un portal exacto.
El modelo no puede añadir precisión ausente en la fuente ni recuperar datos
censurados. Conserva los campos publicados en `dim_address` sin alterarlos.

Se mantienen **todas las detenciones de `fact_arrests`**, incluso sin dirección,
CP, fecha o ACS, mediante LEFT JOIN y sin filtros que eliminen hechos. Las
ubicaciones ausentes o censuradas conservan sus NULL e indicadores de calidad.
Si falta la fila de `dim_address`, se mantiene el `address_id` del hecho y
`has_address_data = false`. Si un CP no tiene referencia en el catálogo, se
conserva su valor original y `has_postal_reference = false`.

No se generan filas artificiales de detenciones para CP-años sin eventos. Para
mostrar ceros en todas las zonas, partir de `dim_postal_codes` y unir los
recuentos agregados. Añadir direcciones como listas a una fila CP-año no
preservaría su relación con cada detención y por eso se descarta esa alternativa.

## Dependencias y tiempo

| Modelo Gold | Uso y cardinalidad necesaria |
| --- | --- |
| `fact_arrests` | Una detención por `arrest_number`. |
| `dim_date` | Fecha y año de ocurrencia por `arrest_occurred_date_key`. |
| `dim_address` | Una ubicación por `address_id`; todos sus atributos de dirección se conservan. |
| `dim_postal_codes` | Una fila por CP; geometría y versión postales sin modificaciones. |
| `dim_census_socioeconomic` | Vista Gold con una fila por CP ZCTA. Lee el Silver existente sin reconstruirlo. |

Se conserva `arrest_occurred_date_time` del hecho y se obtienen `arrest_occurred_date`
y `year` de `dim_date`, no del reporte. Si falta la fecha, el año queda NULL sin perder
la detención ni su ubicación. Varias detenciones de una misma persona son
eventos distintos: no se cuentan personas únicas, cargos, delitos o condenas.
No se unen puentes, cargos ni delitos por compartir informe.

## Columnas finales

El contrato completo está en
[`_marts.yml`](../models/gold/marts/_marts.yml).

| Columnas | Significado |
| --- | --- |
| `arrest_number` | Clave única de detención, sin modificar. |
| `arrest_occurred_date_time`, `arrest_occurred_date`, `year` | Timestamp, fecha y año de ocurrencia; pueden faltar. |
| `address_id`, `has_address_data` | Clave original del hecho y existencia de la ubicación en Gold. |
| `block_address` | Dirección aproximada por bloque publicada, sin transformaciones adicionales. |
| `latitude`, `longitude` | Coordenadas originales con su precisión publicada, incluso si sus flags las identifican como no utilizables. |
| `point_geography` | Punto EPSG:4326 solo si las coordenadas están en rango y los indicadores no señalan censura, ausencia o invalidez; NULL en otro caso. Puede existir aunque falte CP. |
| `neighborhood`, `reporting_area`, `census_block_2020` | Barrio, área de reporte y referencia textual al bloque censal de 2020. |
| `cp`, `cp_status`, `has_postal_reference` | CP original, estado de su asignación y existencia de ese CP en el catálogo postal. No es la residencia de la persona detenida. |
| `is_location_redacted`, `has_missing_coordinates`, `has_invalid_coordinates` | Indicadores originales de calidad/censura; NULL si no se encontró la ubicación. |
| `postal_year_arrest_count` | Total de detenciones del CP-año, repetido en sus detenciones. NULL sin CP referenciado o fecha. |
| `postal_year_arrests_per_1000` | Total CP-año × 1000 / NULLIF(población ACS, 0); NULL sin denominador, CP válido o fecha. Repetido, no aditivo. |
| `geography`, `boundary_version` | Geometría postal original y versión; pueden faltar. Distintas del punto de la detención. |
| `zcta_name`, `has_socioeconomic_data` | Nombre ZCTA y correspondencia ACS por código; no garantiza disponibilidad de todas las estimaciones. |
| `acs_year`, `acs_period` | Constantes `2024` y `2020–2024`. |
| `median_household_income`, `income_margin_of_error` | Renta mediana anual por hogar en USD de 2024 y margen de error al 90 %. |
| `population` | Población estimada de la ZCTA completa, fija entre años y detenciones. |
| `median_home_value`, `median_monthly_rent` | Valor mediano de vivienda ocupada por propietarios y alquiler contractual mediano mensual, USD. |
| `income_top_coded`, `home_value_top_coded`, `rent_top_coded` | Flags originales de censura superior; NULL sin ACS. Las medianas censuradas se publican como NULL. |
| `income_lower_bound`, `home_value_lower_bound`, `rent_lower_bound` | Solo con censura superior: renta > 250000 USD, vivienda > 2000000 USD, alquiler > 3500 USD/mes. No son estimaciones exactas. |
| `income_quintile`, `income_level` | Quintil 1–5 y etiqueta muy bajo, bajo, medio, alto o muy alto; NULL sin quintil. |

`postal_year_arrests_per_1000` sustituye a la antigua columna agregada
`arrests_per_1000`: el nombre explicita que la tasa pertenece a toda la zona-año,
no a la dirección ni al arresto individual.

## Consulta y mapas

Para obtener los recuentos por zona y año sin perder el detalle almacenado:

```sql
select cp, year, count(*) as arrest_count,
       max(postal_year_arrests_per_1000) as postal_year_arrests_per_1000
from {{ ref('mart_arrest_socioeconomic') }}
where has_postal_reference and year is not null
group by cp, year
```

Es un ejemplo para un consumidor dbt. En una herramienta SQL, sustituir `ref()`
por la tabla publicada, por ejemplo `DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC`.

Para mapas de arrestos, usar `point_geography` o las coordenadas válidas y
mostrar `block_address` en el detalle. No representar coordenadas marcadas como
censuradas o inválidas aunque tengan un valor numérico. Un arresto sin CP puede
tener un punto utilizable: no debe descartarse por eso. Para mapas zonales,
agregar primero por CP-año y usar `geography`, sin confundirla con la ubicación
precisa del evento.

Para contar las detenciones de cualquier selección, usar `COUNT(*)`. Recuperar los totales y
tasas anuales con MAX por CP-año, no sumarlos entre arrestos. Son indicadores del
año completo disponible y no se recalculan al filtrar calles o meses en BI.
Si se necesita la tasa de una selección, recalcular su recuento sobre la
población apropiada; la población postal no es la población de una calle.

Población y medianas se repiten entre arrestos y años. Deduplicar población por
CP para una comparación anual entre zonas y recalcular tasas agregadas; no
sumar tasas ni sumar o promediar medianas para obtener una mediana conjunta.

## Geografía y contexto ACS

La relación es `fact_arrests.address_id → dim_address.address_id → dim_address.cp
→ dim_postal_codes.cp = dim_census_socioeconomic.cp`. El CP ya está resuelto en
Silver mediante coincidencia interior única. No se recalculan geocodificaciones,
geometrías ni asignaciones por cercanía o bloque censal.

ZIP y ZCTA pueden tener límites distintos: se acepta su correspondencia por
código como aproximación. La población ACS corresponde a la ZCTA completa,
no necesariamente al polígono postal o a su parte dentro de Seattle. El
catálogo incluye cartografía de King County y CP procedentes de licencias,
algunos sin polígono; no delimita exclusivamente Seattle.

ACS 2024 5-year representa **2020–2024**, no la economía exacta de cada año de
detenciones. La renta de la zona no es la renta de la persona detenida ni de
su domicilio. Las tasas miden detenciones registradas por población residencial,
no criminalidad ni riesgo individual; visitantes, desplazamientos, cobertura y
prácticas policiales afectan a su interpretación. La asociación no es causalidad.

Silver ya limpia los códigos negativos económicos; las pruebas rechazan su
presencia. El mart no trata marcadores superiores como cantidades exactas:
conserva los flags y umbrales, con medianas censuradas NULL.

Los quintiles se calculan con NTILE(5) sobre una observación por CP con polígono
y renta disponible, no negativa y no censurada, **antes de unir los arrestos**.
Las zonas válidas sin arrestos también forman parte de esa distribución. Se
ordena por renta y CP: rentas iguales pueden quedar en grupos diferentes por
el desempate. Con menos de cinco zonas habrá menos grupos. No son umbrales
absolutos de pobreza ni se recalculan al filtrar en BI.

## Construcción y validaciones

Con perfil autenticado, permisos de escritura, dependencias ya construidas y el mart
de delitos socioeconómico ya publicado:

```bash
DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD \
  dbt build --target dev --select mart_arrest_socioeconomic
```

No añadir `+`: la selección no reconstruye las dependencias. Si aún no está publicado
`mart_crimes_socioeconomic`, añade ese modelo a `--select` para ejecutar la prueba compartida.
Si la tabla ya existe con la columna `arrest_count`, añadir `--full-refresh`
una vez para eliminarla del esquema.

```bash
DBT_BRONZE=DEV_BRONZE DBT_SILVER=DEV_SILVER DBT_GOLD=DEV_GOLD \
  dbt show --target dev --select mart_arrest_socioeconomic_validation --limit 1
```

El diagnóstico de `analyses/` compara detenciones originales y representadas,
cobertura de dirección publicada, puntos, CP y ACS, duplicados y multiplicación
de JOIN. Informa de los arrestos conservados sin ubicación postal, sin referencia
postal y sin fecha: **no son exclusiones y estos grupos pueden solaparse**.
`excluded_arrests` y la diferencia de reconciliación deben valer cero.

Las pruebas YAML comprueban unicidad y no nulos de la clave, correspondencia con
el hecho, etiquetas de renta y relaciones postales y de dirección cuando existe su
referencia. El [test SQL compartido](../tests/singular/gold/marts_socioeconomic_contract.sql)
comprueba la edición ACS, el rango de quintiles, las estimaciones no negativas y
los rangos de los recuentos y tasas de detenciones. Las referencias que faltan
se conservan y se informan con sus flags, no se ocultan mediante INNER JOIN.
