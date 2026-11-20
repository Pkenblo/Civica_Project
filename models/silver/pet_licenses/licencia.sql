-- licencia.sql
-- Parte de staging, sin repetir la limpieza de textos ni la conversión de tipos.
-- Excluye registros sin license_number y elimina duplicados exactos de negocio,
-- ignorando los metadatos de carga. DISTINCT no deduplica solo por license_number.
-- Conserva el CP de origen si tiene cinco dígitos; en otro caso lo deja NULL,
-- sin completar códigos ni eliminar la licencia por un CP inválido.
-- Genera license_id como hash de license_number y animal_name: un cambio de
-- nombre genera otra clave; fecha, especie, razas y CP no intervienen en ella.
-- No elige una versión ni implementa snapshots o vigencias históricas.
-- Las variantes se conservan; las pruebas de unicidad detectan los conflictos
-- con el grano actual previsto de una fila por license_number.

with licenses as (

    select distinct
          license_number
        , license_issue_date
        , animal_name
        , species
        , primary_breed
        , secondary_breed
        -- Staging no valida el formato postal. No completar CP cortos ni limitar a Seattle.
        , case
            when regexp_like(zip_code, '^[0-9]{5}$') then zip_code
            else null
          end as cp
    from {{ ref('stg_pet_licenses') }}
    where license_number is not null

),

candidates as (

    select
          {{ dbt_utils.generate_surrogate_key(['license_number', 'animal_name']) }} as license_id
        , license_number
        , license_issue_date
        , animal_name
        , species
        , primary_breed
        , secondary_breed
        , cp
    from licenses

)

select * from candidates
{% if is_incremental() %}
-- Reemplaza todas las variantes de un número si alguna fila es nueva o distinta.
where license_number in (
    select license_number
    from (
        select * from candidates
        except
        select license_id, license_number, license_issue_date, animal_name,
               species, primary_breed, secondary_breed, cp
        from {{ this }}
    ) as differences
)
{% endif %}
