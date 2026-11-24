# Datos curiosos para visualizar

Seis propuestas para una sección de consulta rápida, calculadas directamente sobre Gold, sin crear otro datamart. Este documento recoge las ideas y los criterios de cálculo; no contiene resultados calculados ni implementa las consultas.

## 1. El nombre de perro y de gato más popular

- Mostrar por separado el nombre más frecuente entre las licencias de perros y entre las de gatos, junto con su número de licencias.
- Fuente: `dim_licenses`.
- Agrupar por `animal_name`, filtrando `species = 'DOG'` o `species = 'CAT'`. Excluir nombres ausentes y mostrar los empates si los hay.
- El recuento representa licencias conservadas en Gold, no necesariamente animales distintos ni toda la población de mascotas.

## 2. La franja horaria con más delitos registrados

- Mostrar la franja de una hora con más delitos, su recuento y el porcentaje sobre los delitos con fecha y hora informadas.
- Fuente: `fact_crimes`, utilizando `offense_date_time`.
- Agrupar por la hora de ocurrencia, no por la hora de registro del informe. Contar una vez cada `crime_id`.
- Indicar el periodo analizado y mantener la referencia horaria de los datos, sin asumir una zona horaria no verificada.

## 3. La calle con más robos de coches y cuántos son

- Mostrar la ubicación con más robos de vehículos y el número de delitos registrados en ella.
- Fuentes: `fact_crimes`, `dim_nibrs` y `dim_address`.
- Filtrar por el código NIBRS `240` y contar delitos distintos por ubicación.
- Gold ofrece `block_address`, una dirección por bloque, no un campo de calle normalizado. Con el dato actual, el resultado debe presentarse como «bloque con más robos de vehículos».
- Para mostrar una calle completa habría que definir y validar cómo agrupar sus distintos bloques e intersecciones. No mezclar ambas unidades sin explicarlo.
- Excluir direcciones ausentes u ocultadas del ranking e indicar cuántos delitos quedan fuera por ese motivo.

## 4. ¿Hay más detenciones en fin de semana que entre semana?

- Comparar lunes a viernes con sábado y domingo según la fecha de ocurrencia de la detención.
- Fuentes: `fact_arrests` y `dim_date`.
- Contar detenciones distintas por `arrest_number`, no personas distintas.

### Cálculo propuesto

```text
Detenciones entre semana ajustadas = total de detenciones de lunes a viernes / 5
Detenciones en fin de semana ajustadas = total de detenciones de sábado y domingo / 2
```

Comparar ambos valores y mostrar la diferencia porcentual respecto al valor entre semana, siempre que este sea mayor que cero. No sumarlos entre sí: son los dos valores que se quieren comparar.

Este ajuste permite comparar los grupos si el periodo contiene el mismo número de lunes, martes, etc., como sucede al seleccionar semanas completas. No equivale a una media diaria de todo el periodo.

Para periodos con semanas incompletas, el cálculo más preciso es dividir cada total por el número real de días de su grupo dentro del intervalo seleccionado, incluyendo los días sin detenciones. Las fechas ausentes se excluyen y se informa de su recuento.

## 5. Cuántos delitos de shooting acaban en detención

- Pregunta propuesta: cuántos delitos con etiqueta de tiroteo tienen una detención asociada.
- Fuentes: `fact_crimes`, `bridge_crime_shooting_types`, `dim_shooting_type` y `fact_arrests`.
- Identificar los delitos con alguna etiqueta de tiroteo y contar cada `crime_id` una sola vez, aunque tenga varias etiquetas.

**Limitación:** compartir `report_id` no demuestra que una detención corresponda a ese delito concreto, ni que ocurriera después. Gold no permite responder literalmente cuántos delitos de shooting «acaban siendo arrestados».

Como aproximación, se puede mostrar «delitos con etiqueta de tiroteo cuyo informe también tiene alguna detención», con su recuento y porcentaje sobre los delitos con etiqueta de tiroteo. La consulta debe comprobar la existencia de una detención sin multiplicar delitos por el número de detenciones o etiquetas. No presentar este indicador como tasa de resolución ni como detenciones por shooting.

## 6. El policía con más detenciones registradas

- Mostrar el agente asociado al mayor número de detenciones y el total correspondiente, incluyendo los empates.
- Fuentes: `fact_arrests` y `dim_agent`.
- Agrupar por `officer_id` mediante `agent_key` y contar `arrest_number` distintos. Excluir las detenciones sin agente identificado del ranking.
- Gold contiene `officer_id`, pero no el nombre del policía. Por tanto, con los datos actuales se mostrará su identificador. Para mostrar el nombre haría falta otra fuente verificada.
- El resultado describe las detenciones asociadas al agente en el conjunto de datos; no mide por sí solo su rendimiento ni garantiza que fuera el único agente participante.

## Criterios comunes

- Mostrar el periodo o la fecha de referencia de cada resultado.
- Explicitar los registros excluidos por datos ausentes cuando afecten al indicador.
- Mantener los granos de Gold y evitar duplicados al consultar puentes o relacionar delitos y detenciones.
- Consultar directamente los hechos, dimensiones y puentes necesarios; no utilizar ni crear un datamart para esta sección.
