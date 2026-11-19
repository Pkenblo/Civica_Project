# Informe de grano de delitos y detenciones de Seattle

**Fecha de las pruebas:** 19 de noviembre de 2026  
**Entorno:** Snowflake DEV, capa RAW  
**Alcance:** todos los lotes cargados en `DEV_BRONZE.RAW.CRIMES` y `DEV_BRONZE.RAW.ARRESTS` (`AUDIT_GRANO_LOTE = 'TODOS'`)

## Conclusión

El **grano** indica qué representa una fila. En `CRIMES`, la unidad observada es **un delito dentro de un informe policial**. En `ARRESTS`, es **un tipo de infracción asociado a una detención**. Las dos tablas RAW contienen varias filas para algunas de esas combinaciones, por lo que las claves propuestas para Silver requieren validar y resolver las repeticiones.

| Entidad en Silver | Grano propuesto | Clave de negocio candidata |
|---|---|---|
| `REPORTS` | Una fila por informe policial | `REPORT_NUMBER` |
| `CRIMES` | Una fila por delito dentro de un informe | `(REPORT_NUMBER, OFFENSE_ID)` |
| `ARREST` | Una fila por registro de detención | `ARREST_NUMBER` |
| `ARREST_OFFENSES` | Una fila por tipo de infracción asociado a una detención | `(ARREST_NUMBER, OFFENSE_TYPE)`, o `(ARREST_NUMBER, OFFENSE_TYPE_ID)` si se usa el catálogo de tipos |

La última clave modela la **asociación a un tipo**. Si el origen distingue dos cargos del mismo tipo dentro de una detención y se necesita conservar ambos, el detalle tendrá que estar a nivel de cargo y requerirá un identificador que los distinga.

## Método y resultados completos

El script `comprobar_grano_seattle.sql` agrupa por cada clave candidata. Antes de agrupar, recorta los espacios de los campos y cuenta los valores vacíos como ausentes. El resumen abarca todas las filas del histórico analizado. Las tres consultas de detalle devuelven hasta 20 grupos cada una.

- **Claves distintas:** número de valores o combinaciones completos.
- **Claves repetidas:** número de claves completas que aparecen en más de una fila.
- **Filas extra:** suma de las filas que sobran al contar una sola fila por cada clave completa. Una clave con cuatro apariciones suma una clave repetida y tres filas extra.
- **Filas sin clave:** filas en las que falta al menos un componente de la clave candidata.

| Tabla | Clave analizada | Filas totales | Filas sin clave | Claves distintas | Claves repetidas | Filas extra | Resultado |
|---|---|---:|---:|---:|---:|---:|---|
| `CRIMES` | `OFFENSE_ID` | 1.579.028 | 0 | 1.575.320 | 3.158 | 3.708 | TIENE REPETICIONES |
| `CRIMES` | `REPORT_NUMBER` | 1.579.028 | 0 | 1.386.771 | 149.914 | 192.257 | TIENE REPETICIONES |
| `CRIMES` | `REPORT_NUMBER + OFFENSE_ID` | 1.579.028 | 0 | 1.575.321 | 3.157 | 3.707 | TIENE REPETICIONES |
| `ARRESTS` | `ARREST_NUMBER` | 147.187 | 0 | 110.143 | 26.244 | 37.044 | TIENE REPETICIONES |
| `ARRESTS` | `ARREST_NUMBER + OFFENSE_TYPE` | 147.187 | 0 | 145.635 | 1.481 | 1.552 | TIENE REPETICIONES |
| `ARRESTS` | `REPORT_NUMBER` | 147.187 | 0 | 84.963 | 34.787 | 62.224 | TIENE REPETICIONES |

## CRIMES

Un mismo informe agrupa varios delitos. Por ejemplo, el informe `2023-018027` contiene **18 filas con 18 `OFFENSE_ID` distintos**. El informe `2025-162098` presenta el mismo patrón. La agrupación por `REPORT_NUMBER` da **1.386.771 números de informe** y **149.914 números repetidos** en esta tabla. El informe es una entidad de un nivel superior al delito.

Al incorporar `REPORT_NUMBER` a `OFFENSE_ID`, el número de combinaciones distintas pasa de **1.575.320** a **1.575.321**. Como ambas columnas están completas en la prueba, la diferencia de una combinación implica que **un solo `OFFENSE_ID` aparece asociado a más de un informe**. Es `71157844528`, con dos filas, dos informes, dos lotes y dos ficheros. Hay que comparar las dos filas para saber si corresponden a una corrección del número de informe o a otro caso de reutilización del identificador.

La pareja `(REPORT_NUMBER, OFFENSE_ID)` tiene **3.157 claves repetidas** y **3.707 filas extra**. El detalle muestra grupos como `12674839644`, con cuatro filas para el mismo informe en cuatro lotes y cuatro ficheros. Eso demuestra que la combinación puede reaparecer durante la ingesta. Distinguir una fila idéntica recargada de una versión corregida requiere comparar sus atributos de origen.

**Implicación para Silver.** Conservar el informe y el identificador del delito al consolidar los registros. La pareja es la clave candidata con la evidencia disponible. La revisión de `71157844528` determinará cómo tratar ese caso antes de fijar la regla de consolidación.

## ARRESTS

Un número de detención puede aparecer en varias filas dentro del mismo fichero. La detención `20-005825` tiene **11 filas con 11 valores distintos de `OFFENSE_TYPE`**, todos en un único informe, lote y fichero. Esto demuestra que la multiplicidad por tipo ya existe dentro de una carga.

De las **147.187 filas**, hay **110.143 números de detención distintos** y **145.635 parejas distintas de detención y tipo de infracción**. La diferencia equivale a **35.492 asociaciones distintas adicionales** al pasar del nivel detención al nivel detención–tipo. Al agrupar por la pareja completa todavía quedan **1.481 claves repetidas** y **1.552 filas extra**. El resumen mide esas repeticiones. Para identificar su causa hacen falta las filas originales de esas parejas.

**Implicación para Silver.** `ARREST` reúne los atributos propios de la detención y se identifica por `ARREST_NUMBER`. `ARREST_OFFENSES` contiene las asociaciones de cada detención con los tipos de infracción. Un recuento de detenciones en el histórico analizado da **110.143 números de detención distintos**. Las **145.635** combinaciones miden asociaciones detención–tipo observadas en RAW.

## Validación pendiente para Silver

1. Ejecutar el resumen con `AUDIT_GRANO_LOTE = 'INITIAL_LOAD'` y compararlo con `TODOS`. Los CSV aportados corresponden al histórico completo. La comparación permitirá ver qué repeticiones ya existían en la carga inicial.
2. Revisar las dos filas del delito `71157844528` y comparar las filas de las parejas repetidas en ambas tablas. Usar `BATCH_ID` y `SOURCE_FILE` para rastrear la procedencia, y los atributos del origen para distinguir copias, cambios y posibles registros diferentes.
3. Validar unicidad y ausencia de nulos sobre las claves elegidas después de consolidar. Para `ARREST`, comprobar también que los atributos que se conservan a nivel de detención sean coherentes entre las filas del mismo `ARREST_NUMBER`.

## Anexos

### A. Informes con varios delitos distintos

| Número de informe | Filas | Delitos distintos |
|---|---:|---:|
| `2023-018027` | 18 | 18 |
| `2025-162098` | 18 | 18 |
| `2023-124881` | 16 | 16 |
| `2023-346113` | 15 | 15 |
| `2024-337659` | 14 | 14 |
| `2020-220030` | 13 | 13 |
| `2022-015811` | 13 | 13 |
| `2022-297056` | 12 | 12 |
| `2023-240907` | 12 | 12 |
| `2026-037979` | 12 | 12 |
| `2020-113942` | 11 | 11 |
| `2023-232252` | 11 | 11 |
| `2024-008884` | 11 | 11 |
| `2025-045004` | 11 | 11 |
| `2025-351641` | 11 | 11 |
| `2011-409287` | 10 | 10 |
| `2021-053061` | 10 | 10 |
| `2023-033586` | 10 | 10 |
| `2024-130040` | 10 | 10 |
| `2024-131616` | 10 | 10 |

### B. Identificadores de delito repetidos

| ID de delito | Filas | Informes distintos | Lotes distintos | Ficheros distintos |
|---|---:|---:|---:|---:|
| `71157844528` | 2 | 2 | 2 | 2 |
| `12674839644` | 4 | 1 | 4 | 4 |
| `37993681921` | 4 | 1 | 4 | 4 |
| `74710366523` | 4 | 1 | 4 | 4 |
| `74814130908` | 4 | 1 | 4 | 4 |
| `74814177137` | 4 | 1 | 4 | 4 |
| `74814295595` | 4 | 1 | 4 | 4 |
| `74814362923` | 4 | 1 | 4 | 4 |
| `74814376091` | 4 | 1 | 4 | 4 |
| `74814395596` | 4 | 1 | 4 | 4 |
| `74814411267` | 4 | 1 | 4 | 4 |
| `74814440878` | 4 | 1 | 4 | 4 |
| `74814472417` | 4 | 1 | 4 | 4 |
| `74814480256` | 4 | 1 | 4 | 4 |
| `74814490122` | 4 | 1 | 4 | 4 |
| `74814579107` | 4 | 1 | 4 | 4 |
| `74814585636` | 4 | 1 | 4 | 4 |
| `74814632321` | 4 | 1 | 4 | 4 |
| `74814664532` | 4 | 1 | 4 | 4 |
| `74814677312` | 4 | 1 | 4 | 4 |

### C. Detenciones con varias filas

Los extremos de `OFFENSE_TYPE` corresponden al mínimo y máximo textual del grupo. Las columnas de lotes y ficheros reflejan cuántos valores distintos aparecen para cada número de detención.

| ID de detención | Filas | Tipos distintos | Tipo mínimo | Tipo máximo | Informes distintos | Lotes distintos | Ficheros distintos |
|---|---:|---:|---|---|---:|---:|---:|
| `20-005825` | 11 | 11 | RCW - 46.61.024.1 \| ELUDING A POLICE VEHICLE | SMC - 12A.16.050 \| RESISTING ARREST | 1 | 1 | 1 |
| `22-013323` | 10 | 10 | RCW - 46.20.342.1A \| DWLS 1ST DEGREE | SMC - 12A.16.040 \| FALSE REPORTING - FALSE REPORT | 1 | 1 | 1 |
| `23-005139` | 10 | 10 | RCW - 46.61.522 \| VEHICULAR ASSAULT | SMC 11.56.020 \| PRSN UNDER THE INFLUENCE OF INTOXICANTS/DRUGS - DUI-DRUGS/LIQUOR | 1 | 1 | 1 |
| `24-005132` | 10 | 10 | RCW - 46.61.024.1 \| ELUDING A POLICE VEHICLE | SMC 11.56.020 \| PRSN UNDER THE INFLUENCE OF INTOXICANTS/DRUGS - DUI-DRUGS/LIQUOR | 1 | 1 | 1 |
| `20-005278` | 9 | 9 | RCW - 9A.36.041 \| ASSAULT - ASSAULT 4 | RCW 9A.46.020.2B I HARASSMENT - FELONY PREVIOUS CONVICTION | 1 | 1 | 1 |
| `21-002478` | 9 | 9 | RCW - 69.41.030.2A \| LEGEND DRUG-SELL NO PRESC | SMC - 12A.14.080(A) \| SELL/PURCHASE/POSSESS DANGEROUS KNIFE/DEADLY WEAPON | 1 | 1 | 1 |
| `24-000667` | 9 | 9 | RCW - 9A.36.041 \| ASSAULT - ASSAULT 4 | SMC 11.56.020 \| PRSN UNDER THE INFLUENCE OF INTOXICANTS/DRUGS - DUI-DRUGS/LIQUOR | 1 | 1 | 1 |
| `24-003578` | 9 | 9 | RCW - 46.61.500 \| RECKLESS DRIVING | SMC - 12A.16.050 \| RESISTING ARREST | 1 | 1 | 1 |
| `24-004574` | 9 | 9 | RCW - 9A.36.031 \| ASSAULT - ASSAULT 3 | SMC - 12A.16.050 \| RESISTING ARREST | 1 | 1 | 1 |
| `24-006587` | 9 | 9 | RCW - 46.20.005 \| NO VALID OPERATORS LIC W/O ID | RCW - 9A.56.170 \| POSSESSION OF  STOLEN PROPERTY 3 | 1 | 1 | 1 |
| `24-008698` | 9 | 9 | RCW - 46.61.024.1 \| ELUDING A POLICE VEHICLE | SMC 11.56.020 \| PRSN UNDER THE INFLUENCE OF INTOXICANTS/DRUGS - DUI-DRUGS/LIQUOR | 1 | 1 | 1 |
| `25-002609` | 9 | 9 | 23993 \| 9A.60.040 \| CRIMINAL IMPERSONATION | SMC - 12A.14.080(B) \| CARRY CONCEALED UNCONCEALED WEAPON ON PERSON | 1 | 1 | 1 |
| `19-013069` | 8 | 8 | RCW - 9A.56.050 \| THEFT 3, SHOPLIFTING | SMC - 12A.14.140(A) \| UNLAWFUL CARRY PISTOL | 1 | 1 | 1 |
| `19-015077` | 8 | 8 | Outside Agency -- Felony Warrant | SMC - 12A.16.010 \| OBSTRUCTING A PUBLIC OFFICER | 1 | 1 | 1 |
| `20-002528` | 8 | 8 | RCW - 46.20.342.1.C \| DWLS 3RD DEGREE | RCW - 9A.56.160 \| POSSESSION OF STOLEN PROPERTY 2 | 1 | 1 | 1 |
| `20-007679` | 8 | 8 | 2299 \| 9A.56.063 \| POSSESSION OF VEHICLE THEFT TOOLS | RCW - 9A.56.330.1 \| POSSESSION OF ANOTHERS ID | 1 | 1 | 1 |
| `21-003616` | 8 | 8 | RCW - 69.41.030.2A \| LEGEND DRUG-SELL NO PRESC | RCW - 9A.56.160 \| POSSESSION OF STOLEN PROPERTY 2 | 1 | 1 | 1 |
| `21-012192` | 8 | 8 | RCW - 69.50.4013 \| DRUGS - METHAMPHETAMINE - POSSESSION | SMC - 12A.16.040 \| FALSE REPORTING - OBSTRUCT | 1 | 1 | 1 |
| `22-010823` | 8 | 8 | RCW - 10.99.040 \| NO CONTACT ORDER VIOLATION | SMC - 12A.16.040 \| FALSE REPORTING - FALSE REPORT | 1 | 1 | 1 |
| `22-013287` | 8 | 8 | RCW - 46.20.342.1.C \| DWLS 3RD DEGREE | SMC - 12A.14.080(F) \| FURTIVELY CARRYING A DANGEROUS WEAPON | 1 | 1 | 1 |

## Fuentes

| Exportación de Snowflake | Contenido |
|---|---|
| `Prueba_grano_2026-11-19-1858.csv` | Resumen de las seis claves candidatas sobre todos los lotes |
| `Prueba_grano_2026-11-19-1859.csv` | 20 informes con varios identificadores de delito |
| `Prueba_grano_2026-11-19-1859(1).csv` | 20 identificadores de delito repetidos |
| `Prueba_grano_2026-11-19-1900.csv` | 20 números de detención repetidos, ordenados por tipos de infracción distintos |
