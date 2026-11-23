Las edades de los delincuentes y policias van cambiando por lo que tengo 2 opciones, asociar la edad a la detencion o hacer un screenshot.

Cuando tengo los sugetos sin identificar puedo hacer una relacion 1/0 donde no es obligatorio tener sugeto en un crimen y en vez de Id guardamos Null si es vacio o Private si es redacted o algo asi.

El stagin es solo una vista por lo que aunque haya incrementalidad este si tiene que consultar toda la tabla.

Tengo que hacer incrementalidad en todas las tablas? de silver? y si es asi no tarda mucho?

Tengo la tabla de census, esta realmente no se relaciona con el resto, si que tiene cp pero no tiene mucho sentido meterla asi ya que si la meto separada me puedo permitir hacerla estatica y no tener que actualizarla en cada build ya que los datos no van a cambiar nunca.

Mis datamarts no tienen agregaciones ya que me interesa sacarlos con el grano mas fino para poder luego poner filtros en la visualizacion esto esta bien?

el mart_crimes_socioeconomic tarda mucho.

tengo un mart incremental en Gold que cuenta delitos por código postal y año. Si corrigen la fecha de un delito y pasa de 2024 a 2025, mi modelo recalcula el total de 2025, pero el de 2024 se queda como estaba y sigue contando ese delito. ¿Cómo recomendarías recalcular ambos años sin dejar de usar un modelo incremental?