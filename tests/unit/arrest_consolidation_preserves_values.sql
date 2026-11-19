-- Regresión con salida simulada de staging: nulos complementarios, false/0,
-- prioridad por completitud y después ingesta, separación de personas y barrera de REDACTED.
-- Devuelve filas solo si la consolidación pierde datos o difiere del resultado esperado.

with defaults as (

    select
          null::varchar as arrest_number
        , null::timestamp_ltz as ingested_at
        , null::timestamp_ntz as arrest_occurred_date_time
        , null::timestamp_ntz as arrest_reported_date_time
        , null::varchar as report_number
        , null::varchar as arrest_type
        , null::varchar as precinct
        , null::varchar as sector
        , null::varchar as beat
        , null::varchar as cad_clearance
        , null::varchar as cad_initial_call_type
        , null::number as cad_priority
        , null::boolean as crisis_involved
        , null::boolean as complaint_involved
        , null::boolean as force_involved
        , null::boolean as terry_stop
        , null::boolean as demonstration
        , null::varchar as officer_id
        , null::number as officer_age
        , null::varchar as officer_gender
        , null::varchar as officer_race
        , null::varchar as officer_squad
        , null::varchar as officer_title
        , null::varchar as subject_id
        , null::varchar as subject_age_range
        , null::varchar as subject_gender
        , null::varchar as subject_race
        , null::varchar as block_address
        , null::number(18, 5) as latitude
        , null::number(18, 5) as longitude
        , null::varchar as neighborhood
        , null::varchar as reporting_area
        , null::varchar as census_block_2020
        , false as is_location_redacted
        , false as has_invalid_coordinates

),

fixture as (

    select d.* replace (
        'A1' as arrest_number, '2026-11-01 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'O1' as officer_id, 'OFFICER' as officer_title,
        47.61235::number(18, 5) as latitude, false as force_involved, 0 as cad_priority
    ) from defaults d
    union all
    select d.* replace (
        'A1' as arrest_number, '2026-11-02 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        '100 MAIN ST' as block_address, -122.34568::number(18, 5) as longitude
    ) from defaults d
    union all
    select d.* replace (
        'A2' as arrest_number, '2026-11-01 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'O2' as officer_id, 'OLD TITLE' as officer_title
    ) from defaults d
    union all
    select d.* replace (
        'A2' as arrest_number, '2026-11-02 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'O2' as officer_id, 'NEW TITLE' as officer_title
    ) from defaults d
    union all
    select d.* replace (
        'A3' as arrest_number, '2026-11-01 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'P1' as subject_id, 'ADULT' as subject_age_range
    ) from defaults d
    union all
    select d.* replace (
        'A3' as arrest_number, '2026-11-02 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'P2' as subject_id
    ) from defaults d
    union all
    select d.* replace (
        'A4' as arrest_number, '2026-11-01 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'OLD PUBLIC ADDRESS' as block_address, 47.61235::number(18, 5) as latitude
    ) from defaults d
    union all
    select d.* replace (
        'A4' as arrest_number, '2026-11-02 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        true as is_location_redacted
    ) from defaults d
    union all
    select d.* replace (
        'A4' as arrest_number, '2026-11-03 00:00:00 +00:00'::timestamp_ltz as ingested_at,
        'NEW PUBLIC ADDRESS' as block_address
    ) from defaults d

),

consolidated as (

    {{ consolidate_arrests('fixture') }}

),

actual as (

    select arrest_number, officer_id, officer_title, subject_id, subject_age_range,
        block_address, latitude, longitude, force_involved, cad_priority
    from consolidated

),

expected as (

    select column1::varchar as arrest_number, column2::varchar as officer_id,
        column3::varchar as officer_title, column4::varchar as subject_id,
        column5::varchar as subject_age_range, column6::varchar as block_address,
        column7::number(18, 5) as latitude, column8::number(18, 5) as longitude,
        column9::boolean as force_involved, column10::number as cad_priority
    from values
        ('A1', 'O1', 'OFFICER', null, null, '100 MAIN ST', 47.61235, -122.34568, false, 0),
        ('A2', 'O2', 'NEW TITLE', null, null, null, null, null, null, null),
        ('A3', null, null, 'P1', 'ADULT', null, null, null, null, null),
        ('A4', null, null, null, null, 'NEW PUBLIC ADDRESS', null, null, null, null)

),

unexpected as (select * from actual minus select * from expected),
missing as (select * from expected minus select * from actual)

select * from unexpected
union all
select * from missing
