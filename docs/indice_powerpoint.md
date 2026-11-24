# Cívica Project — índice para la presentación

**12 minutos previstos; máximo 15.** Los detalles del final quedan para preguntas.

## 1. Qué hace Cívica y de dónde salen los datos · 1 min

- Datos abiertos de Seattle: delitos, detenciones y licencias de mascotas; cartografía de King County y contexto socioeconómico del censo.
- Recorrido en una línea: ingesta externa → Bronze → Staging → Silver → Gold → marts → panel.

## 2. Qué representa cada fila · 2 min

- Por qué no vale contar filas de RAW: una detención aparecía con 11 tipos de infracción en un mismo fichero.
- Claves elegidas: pareja informe–delito, número de detención y número de licencia. Las etiquetas de tiroteo y las infracciones observadas van aparte para no multiplicar los eventos.
- Delitos y detenciones comparten número de informe, pero eso no permite asociar una detención a un delito concreto. NIBRS y la clasificación de Seattle son cosas distintas.

## 3. Qué datos pertenecen a la detención y cuáles a la persona · 1 min

- **Edad del agente y rango de edad del sujeto en `arrest`:** corresponden al momento de la detención. Si una persona aparece años después, su edad nueva no debe cambiar la del evento antiguo.
- La unidad y el cargo del agente también se guardan en la detención. Si falta el identificador del sujeto o del agente, la referencia queda nula; la detención se conserva.

## 4. Cómo se relacionan los datos por código postal · 2 min

- Delitos y detenciones no traen CP directo y algunas ubicaciones están censuradas. Cruce del punto publicado con los polígonos: solo se asigna CP si cae en el interior de una única zona; si no, queda nulo con su motivo.
- Las licencias usan su ZIP declarado. El censo ACS 2020–2024 usa ZCTA: cruzar por código es una aproximación, no una igualdad de límites. La renta es de la zona, no de las personas implicadas.

## 5. Por qué no todo es incremental ni todo se agrega · 3 min

- Staging son vistas que limpian sin deduplicar. En los modelos incrementales, una versión nueva reemplaza la fila entera, incluidos los nulos. El corte es por fecha de ingesta, no por fecha del hecho: una llegada con marca anterior o igual al máximo puede quedar fuera.
- Marts de detalle para filtrar por ubicación, fecha o tipo: el de delitos solo incluye los que se pueden dibujar; el de detenciones conserva también los que no tienen punto. El mart de licencias y delitos, en cambio, agrega cada fuente por separado y las compara por CP y año.
- Ejemplo de la corrección **2024 → 2025**: la vista de delitos y licencias refleja ambos años en cuanto se corrige Gold; el mart incremental de detenciones recalcula tanto el grupo CP–año anterior como el nuevo.

## 6. Qué se ve en el panel y cómo leerlo · 2 min

- Enseñar un CP en el mapa de delitos y mascotas: color = casos registrados; tamaño del icono = licencias por caso. Distinguir emisiones anuales de acumuladas. Se cuentan licencias, no animales únicos.
- Enseñar un mapa de detalle con contexto económico. Los puntos son ubicaciones publicadas, a veces aproximadas por manzana. Comparar zonas no demuestra causalidad y un cero no garantiza cobertura.

## 7. Qué está validado y qué queda pendiente · 1 min

- Auditoría del grano en RAW, controles de unicidad y referencias, parseo de dbt y pruebas locales del panel. Pendiente: construcción integral de la versión actual con datos reales en Snowflake DEV y revisión de la cobertura postal.

### Solo si hay tiempo o sale en preguntas

- Horarios de carga: diferencia entre la hora local y la de Seattle. No dar por activa la programación diaria sin comprobarla.
- Rendimiento: una vista consulta sus fuentes y un incremental puede seguir leyendo históricos. El coste del mart socioeconómico de delitos se debe medir en DEV.
- Correlaciones: Pearson por CP y año; comparar recuento de licencias por especie no es lo mismo que comparar su porcentaje. El umbral mínimo cambia la muestra.
- Curiosidades: mostrar una tarjeta. Si es la de tiroteos, cuenta delitos cuyo informe también tiene alguna detención; no mide resolución.

Apuntes de referencia: [Preguntas del proyecto](Preguntas.md), [problemas durante el desarrollo](Problemas_durante_el_desarroyo.md), [diagrama de Silver](silver_diagram.svg) y [diagrama de Gold](../gold_diagram.dbml).
