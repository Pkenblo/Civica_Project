# Panel de Seattle

En Linux, haz doble clic en **Abrir panel.desktop** (si el escritorio lo pide, permite ejecutar el lanzador). Se abre una terminal con la dirección local y el panel en el navegador. Mantén la terminal abierta durante la presentación y ciérrala al terminar. También puedes arrancarlo con `python3 visualizacion/panel.py` desde la raíz del proyecto.

Cada apertura de la página y cada recarga del navegador ejecutan `panel.sql` únicamente contra **DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES**. Cambiar de gráfico, especie o periodo usa los datos ya cargados. Si la consulta falla, se muestra la última lectura completa de ese perfil con un aviso y su fecha UTC. Sin una primera lectura correcta no se muestran gráficos. Abrir `index.html` directamente no inicia el servicio.

El mapa superpone los polígonos del mart sobre calles de OpenStreetMap (las calles requieren Internet). **Vista** contiene solo robos de vehículos, robos y hurtos seleccionados y tiroteos/homicidios. El verde representa el indicador elegido y los marcadores crecen según el cociente licencias/casos. Con **Gatos+Perros** aparecen juntos gatos morados y perros naranjas, con la misma escala. Sin casos no hay cociente ni marcador. La casilla **Licencias acumuladas hasta el año elegido**, activada por defecto, usa las columnas `cumulative_*_license_count` del mart, incluidas las emisiones anteriores a 2024 y los años sin delitos. Desmarcarla usa solo las emisiones del año elegido. Reconstruir `mart_crimes_pet_licenses` si la tabla aún no publica estas cuatro columnas. No se consulta `DIM_LICENSES` desde esta pestaña. Véase la [definición del mart](../docs/marts.md).

En las selecciones **Gatos**, **Perros** y **Gatos+Perros**, los círculos se sustituyen por iconos SVG locales de gato morado y perro naranja. Mantienen el mismo cálculo de tamaño: lado = `52 × sqrt(cociente / máximo)`, de modo que duplicar el cociente duplica el área del recuadro del icono. En la vista conjunta usan el mismo máximo y se dibujan lado a lado. Los otros grupos de especies mantienen sus círculos.

Todos los controles de fecha y gráficos se limitan a **2024–2026**, con **2024 por defecto** (enero de 2024 en la pestaña mensual). La opción «Todos (2024–2026)» de las tablas suma solo esos tres años y no sus saldos acumulados. Las gráficas de evolución usan siempre recuentos anuales. Los otros dos mapas siguen leyendo sus respectivos marts de detalle; no pueden obtener ubicaciones individuales del mart CP-año. Leaflet 1.9.4 se sirve localmente; su licencia está en `leaflet/LICENSE`.

## Antes del primer uso

### Detenciones y contexto económico

La tercera pestaña lee **`DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC`**. Tiene dos selectores: año de la detención y variable económica (renta, alquiler o precio de vivienda). Los puntos azules conservan las coordenadas válidas publicadas por el mart, incluidos los que no tienen CP. Se agrupan únicamente coordenadas idénticas, sin redondeo extra ni desplazamiento; al pulsar se muestran bloque aproximado, barrio, CP y número de detenciones. Se excluyen del dibujo los eventos sin `point_geography` y se informa de su cantidad, sin inferir posiciones.

Las zonas se colorean por nivel bajo, medio y alto de la variable elegida, con cortes P33/P67 calculados una vez sobre CP únicos con polígono y mediana disponible, no censurada. Los empates de valor permanecen juntos. Es una agrupación de la visualización, distinta del quintil de renta publicado. Debajo aparecen **tres comparativas** (renta, alquiler y vivienda), cada una con tabla del año elegido y barras anuales. La media divide las detenciones entre el número de zonas del grupo: incluye zonas con cero casos ese año y no corrige población ni actividad policial. Se cuentan eventos de detención, no delitos ni personas únicas.

Para conservar zonas con cero detenciones anuales se usa `DIM_POSTAL_CODES` como catálogo y se recupera el contexto ACS de cada CP desde cualquier año del mart. Un CP sin eventos en todo el histórico no tiene contexto económico recuperable en este mart: queda gris y fuera de las comparativas, sin imputación. No se suman `postal_year_arrest_count` ni sus tasas repetidas; solo `arrest_count`. La población y las medianas no se suman. Los valores censurados se muestran como «Más de…» y no se usan para formar los grupos. El contexto ACS 2020–2024 es fijo, no una serie económica histórica; ver [contrato del mart](../docs/mart_arrest_socioeconomic.md). Esta pestaña no usa el filtro de 50 licencias de mascotas.

Pruebas locales con datos sintéticos desde la raíz: `python3 -m unittest discover -s visualizacion/tests -v` y `node visualizacion/tests/socio.test.cjs`. No sustituyen la validación del mart desplegado en Snowflake.

Si tu rol todavía no tiene acceso, un administrador puede ejecutar:

```sql
GRANT USAGE ON SCHEMA DEV_GOLD.MARTS TO ROLE DEV_VISUALIZACION_ROLE;
GRANT SELECT ON TABLE DEV_GOLD.MARTS.MART_ARREST_SOCIOECONOMIC TO ROLE DEV_VISUALIZACION_ROLE;
```

### Otros mapas

La pestaña **Delitos por ubicación** consulta un mes de `DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC` cuando la abres (por defecto enero de 2024). Los puntos conservan la precisión publicada y se colorean por `nibrs_category`; se puede filtrar también por código y descripción NIBRS. Los puntos coincidentes comparten marcador y los sectores muestran la proporción de cada categoría. El detalle incluye bloque aproximado, barrio y CP, sin descargar identificadores de casos.

El fondo postal permite elegir **renta del hogar, alquiler o precio de vivienda**, con niveles bajo/medio/alto calculados con el mismo criterio P33/P67 que en la pestaña 3. El contexto se recupera una sola vez por CP desde el mart de delitos sin filtrar mes o categoría y se cruza con `DIM_POSTAL_CODES` para conservar polígonos con cero delitos en el mes. Un CP sin ningún delito en todo el mart no tiene contexto recuperable: queda gris. Los grupos no se recalculan con los filtros, y pueden diferir de los de detenciones porque el contexto recuperable no necesariamente cubre los mismos CP.

Puedes filtrar por nivel y por importe mínimo/máximo de la variable elegida. Cambiar de variable limpia los límites porque las unidades cambian (alquiler mensual frente a renta anual, por ejemplo). Sin filtro se conservan delitos con coordenadas pero sin CP o contexto. Los valores censurados no se imputan: aparecen como «Más de…» y no entran en rangos de valores exactos ni grupos económicos. La leyenda de categorías cuenta solo los delitos de la selección. Los filtros trabajan en memoria; cargar otro mes requiere conexión. Los polígonos y su opacidad se pueden activar o modificar sin ocultar los puntos. El rol necesita `USAGE` en `MARTS` y `SELECT` sobre el nuevo mart y `DEV_GOLD.GOLD.DIM_POSTAL_CODES`.

Debajo del mapa aparecen tres bloques (renta, alquiler y vivienda), cada uno con tabla del año del mes elegido y barras anuales 2024–2026. **Cada bloque tiene su selector independiente**, con «Todos los tipos», las categorías del proyecto y los códigos NIBRS. Los selectores de los gráficos no modifican el mapa ni los otros gráficos y se conservan al cambiar de mes. Estas comparativas usan el año completo disponible, no solo el mes del mapa, y no dependen de sus filtros ni del zoom. Los grupos económicos son fijos y la media incluye los CP con cero casos del tipo elegido. Los CP sin polígono o valor económico comparable quedan fuera; no se imputa renta a delitos sin CP. Un año sin registros en el mart se señala con guion en vez de asumir cero. Los recuentos anuales se descargan agregados por CP-año y tipo, sin identificadores de delitos, desde el mismo mart.

Pruebas de este mapa: `python3 -m unittest discover -s visualizacion/tests -v` y `node visualizacion/tests/crime_economy.test.cjs`.

En **Vista** se eligen robos de vehículos, robos y hurtos seleccionados o tiroteos/homicidios, todos publicados en el mismo mart. Las etiquetas de tiroteo no multiplican los delitos y un mismo delito puede contribuir a dos indicadores. Construir primero `mart_crimes_pet_licenses` en dbt. Si usas el rol de lectura del proyecto, los permisos adicionales son:

```sql
GRANT USAGE ON SCHEMA DEV_GOLD.MARTS TO ROLE DEV_VISUALIZACION_ROLE;
GRANT SELECT ON TABLE DEV_GOLD.MARTS.MART_CRIMES_PET_LICENSES TO ROLE DEV_VISUALIZACION_ROLE;
GRANT SELECT ON TABLE DEV_GOLD.MARTS.MART_CRIMES_SOCIOECONOMIC TO ROLE DEV_VISUALIZACION_ROLE;
```

**Análisis de correlaciones:** abre el enlace del panel a `correlaciones.html`. Usa la misma consulta al mart unificado, no los CSV antiguos, con licencias anuales y año inicial 2024.

El servicio utiliza el perfil **`civica`** de la configuración personal del conector Python de Snowflake. Puedes seleccionar otro con la variable `SNOWFLAKE_CONNECTION_NAME` al lanzar el proceso. Configura un warehouse y un rol con `USAGE` sobre el warehouse, la base y el esquema, y `SELECT` sobre `FACT_CRIMES`, `FACT_ARRESTS`, `DIM_ADDRESS`, `DIM_LICENSES` y `DIM_POSTAL_CODES`. Las tablas deben estar publicadas.

Si aún no tienes perfil, consulta la [ubicación de `connections.toml` en tu sistema](https://docs.snowflake.com/en/developer-guide/python-connector/python-connector-connect#connecting-using-the-connections-toml-file). Ejemplo para iniciar sesión directamente con usuario y contraseña:

```toml
[civica]
account = "<organizacion>-<cuenta>"
user = "<usuario>"
authenticator = "snowflake"
warehouse = "<warehouse>"
role = "<rol_de_lectura>"
```

Introduce la contraseña en la terminal del lanzador; no se muestra al escribir ni se guarda en el archivo. Si usas un código temporal de una aplicación de autenticación, ejecuta `python3 visualizacion/panel.py --codigo-mfa` desde la raíz y escribe en la terminal el código vigente cuando se solicite. Si tu organización usa SSO corporativo, configura `authenticator = "externalbrowser"` en su lugar.

Si Python no tiene instalado el conector, ejecuta una vez:

```sh
cd visualizacion
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

El lanzador usará ese entorno automáticamente. La copia local se guarda en `.cache/` y contiene solo recuentos y geometrías postales. Si reasignas un perfil a otra cuenta, usa otro nombre de perfil o borra antes su copia local.
