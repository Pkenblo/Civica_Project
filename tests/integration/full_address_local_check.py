"""Regresión local de direcciones, Silver y Gold, sin conexión a Snowflake.

python tests/integration/full_address_local_check.py
Requiere Jinja2 y sqlglot. Ejecuta el SQL real traducido a SQLite, emula
delete+insert y usa rectángulos: no valida el motor espacial de Snowflake.
"""

import hashlib
import json
from pathlib import Path
import re
import sqlite3

from jinja2 import Environment, StrictUndefined
import sqlglot
from sqlglot.optimizer.qualify import qualify

from local_dbt_utils import dbt_utils_namespace


ROOT = Path(__file__).resolve().parents[2]
MODELS = {
    'full_address': 'models/silver/geography/full_address.sql',
    'crimes': 'models/silver/crimes/crimes.sql',
    'arrest': 'models/silver/arrests/arrest.sql',
    'dim_address': 'models/gold/dimensions/dim_address.sql',
    'fact_crimes': 'models/gold/facts/fact_crimes.sql',
    'fact_arrests': 'models/gold/facts/fact_arrests.sql',
}
KEYS = {'crimes': 'crime_id', 'arrest': 'arrest_number',
        'fact_crimes': 'crime_id', 'fact_arrests': 'arrest_number'}
MACROS = ''.join((ROOT / f'macros/utils/{name}.sql').read_text()
                 for name in ('address_id', 'after_max_ingested_at'))


def sql_file(conn, path, incremental=False, this='full_address', configs=None):
    rendered = Environment(undefined=StrictUndefined).from_string(MACROS + (ROOT / path).read_text()).render(
        config=lambda **kwargs: (configs.append(kwargs) if configs is not None else None) or '',
        ref=lambda name: name, is_incremental=lambda: incremental, this=this,
        dbt_utils=dbt_utils_namespace(),
    )
    schema = {name: {col[1]: col[2] or 'TEXT' for col in conn.execute(f'pragma table_info({name})')}
              for name, in conn.execute("select name from sqlite_master where type = 'table'").fetchall()}
    expression = qualify(sqlglot.parse_one(rendered, read='snowflake'), dialect='snowflake', schema=schema)
    return expression.sql(dialect='sqlite')


def build(conn, name, incremental=False):
    configs = []
    sql = sql_file(conn, MODELS[name], incremental, name, configs)
    if name == 'full_address':
        assert configs == [{'materialized': 'table'}]
    elif name in ('crimes', 'arrest'):
        assert configs == [dict(materialized='incremental', incremental_strategy='delete+insert',
                                unique_key=KEYS[name], on_schema_change='fail')]
    conn.execute(f'create table next_rows as {sql}')
    if incremental:
        key = KEYS[name]
        conn.execute(f'delete from {name} where {key} in (select {key} from next_rows)')
        conn.execute(f'insert into {name} select * from next_rows')
        conn.execute('drop table next_rows')
    else:
        conn.execute(f'drop table if exists {name}')
        conn.execute(f'alter table next_rows rename to {name}')


def database():
    conn = sqlite3.connect(':memory:')

    def spatial(rectangle, point, interior=False):
        if rectangle is None or point is None:
            return False
        x, y = json.loads(point)
        left, bottom, right, top = json.loads(rectangle)
        return left < x < right and bottom < y < top if interior else left <= x <= right and bottom <= y <= top

    class BoolOr:
        def __init__(self):
            self.value = None

        def step(self, value):
            if value is not None:
                self.value = bool(self.value) or bool(value)

        def finalize(self):
            return None if self.value is None else int(self.value)

    conn.create_function('MD5', 1, lambda value: hashlib.md5(value.encode()).hexdigest() if value is not None else None)
    conn.create_function('ARRAY', -1, lambda *values: json.dumps(values, separators=(',', ':')))
    conn.create_function('JSON_FORMAT', 1, lambda value: value)
    conn.create_function('EQUAL_NULL', 2, lambda left, right: left == right)
    conn.create_function('ST_POINT', 2, lambda x, y: json.dumps([x, y]))
    conn.create_function('ST_COVERS', 2, spatial)
    conn.create_function('ST_CONTAINS', 2, lambda rectangle, point: spatial(rectangle, point, True))
    conn.create_aggregate('LOGICAL_OR', 1, BoolOr)
    conn.executescript('''
        create table postal_codes (cp text, geography text);
        insert into postal_codes values ('98101', '[0, 0, 2, 2]'), ('98102', '[1.5, 1.5, 3, 3]');
        create table reports (report_number text, report_id text);
        create table nibrs (offense_code text, nibrs_key text);
        create table offense_categories (offense_category text, offense_sub_category text, offense_category_id text);
        create table police_add (precinct text, sector text, beat text, police_area_id text);
        insert into police_add values ('NORTH', 'J', 'J1', 'POLICE');
        create table arrest_types (description text, arrest_type_id text);
        create table agents (officer_id text, agent_key text);
        create table subject (sk_person text, subject_key text);
        create table cad_profiles (cad_clearance text, cad_initial_call_type text, cad_priority integer, cad_profile_id text);
        create table dim_report (report_id text, report_date_time text);
        create table dim_date (full_date text, date_key integer);
    ''')
    for name in ('stg_crimes', 'stg_arrests'):
        conn.execute(f'''create table {name} (
            report_number text, offense_id text, arrest_number text, ingested_at text,
            block_address text, latitude real, longitude real, neighborhood text,
            reporting_area text, census_block_2020 text, is_location_redacted boolean,
            has_missing_coordinates boolean, has_invalid_coordinates boolean,
            precinct text, sector text, beat text, source_file text, batch_id text,
            offense_date text, nibrs_offense_code text, offense_category text, offense_sub_category text,
            arrest_occurred_date_time text, arrest_reported_date_time text, arrest_type text,
            officer_id text, subject_id text, officer_age integer, subject_age_range text,
            officer_squad text, officer_title text,
            cad_clearance text, cad_initial_call_type text, cad_priority integer,
            crisis_involved boolean, complaint_involved boolean, force_involved boolean,
            terry_stop boolean, demonstration boolean
        )''')
    report = '2026-000001'
    conn.execute('insert into reports values (?, MD5(?))', (report, report))
    return conn


def add(conn, source, key, day=1, **attributes):
    fields = dict(report_number='2026-000001', offense_id=key, arrest_number=key,
                  ingested_at=f'2026-01-{day:02d}', latitude=None, longitude=None,
                  is_location_redacted=False, has_invalid_coordinates=False)
    fields.update(attributes)
    fields.setdefault('has_missing_coordinates', fields['latitude'] is None or fields['longitude'] is None)
    conn.execute(f'insert into stg_{source} ({", ".join(fields)}) values '
                 f'({", ".join("?" for _ in fields)})', tuple(fields.values()))


def rows(conn, name):
    key = KEYS.get(name, 'address_id')
    return conn.execute(f'select * from {name} order by {key}').fetchall()


def rebuild(conn, incremental=False):
    for name in MODELS:
        build(conn, name, incremental and name in KEYS)


def check(conn, allow_unprocessed=False):
    for path in sorted((ROOT / 'tests/singular').glob('address_*.sql')):
        if allow_unprocessed and path.stem == 'address_event_keys_preserved':
            continue  # El escenario de llegadas tardías comprueba esta excepción expresamente.
        assert not conn.execute(sql_file(conn, path)).fetchall(), path.name
    for name, dimension in [('crimes', 'full_address'), ('arrest', 'full_address'),
                            ('fact_crimes', 'dim_address'), ('fact_arrests', 'dim_address')]:
        assert not conn.execute(f'''select 1 from {name} e left join {dimension} d using (address_id)
                                    where e.address_id is null or d.address_id is null''').fetchall(), name
        key = KEYS[name]
        assert conn.execute(f'select count(*) = count(distinct {key}) from {name}').fetchone() == (1,)
    columns = ', '.join(col[1] for col in conn.execute('pragma table_info(dim_address)'))
    assert conn.execute(f'select {columns} from full_address order by address_id').fetchall() == rows(conn, 'dim_address')
    for address, cp, status in conn.execute('select address_id, cp, cp_status from full_address'):
        assert address in ('UNKNOWN', 'REDACTED') or re.fullmatch('[0-9a-f]{32}', address)
        assert (status == 'matched') == (cp is not None)
    assert conn.execute('select count(*) = count(distinct address_id) from full_address').fetchone() == (1,)
    assert not conn.execute('''select 1 from full_address where is_location_redacted is null
                               or has_missing_coordinates is null or has_invalid_coordinates is null''').fetchall()
    for silver, gold in [('crimes', 'fact_crimes'), ('arrest', 'fact_arrests')]:
        key = KEYS[silver]
        assert conn.execute(f'select {key}, address_id from {silver} order by {key}').fetchall() == conn.execute(
            f'select {key}, address_id from {gold} order by {key}').fetchall()


def main():
    with database() as conn:
        assert conn.execute('select logical_or(null)').fetchone() == (None,)
        rebuild(conn)
        check(conn)
        assert conn.execute('select address_id from full_address order by 1').fetchall() == [('REDACTED',), ('UNKNOWN',)]
        print('PASS: las dos filas abstractas existen con fuentes vacías')

        cases = {
            'unknown': {},
            'invalid_unknown': dict(latitude=999, longitude=1, has_invalid_coordinates=True),
            'police_only': dict(precinct='NORTH', sector='J', beat='J1'),
            'hidden': dict(is_location_redacted=True, block_address='SECRET', latitude=1, longitude=1,
                           neighborhood='SECRET', reporting_area='SECRET', census_block_2020='SECRET'),
            'hidden_empty': dict(is_location_redacted=True),
            'block': dict(block_address='1XX TEST AVE'),
            'neighborhood': dict(neighborhood='DOWNTOWN'),
            'reporting': dict(reporting_area='RA'),
            'census': dict(census_block_2020='530330001001001'),
            'latitude_only': dict(latitude=1),
            'longitude_only': dict(longitude=1),
            # Un RAW fuera de rango puede redondear a 90: su indicador sigue siendo vinculante.
            'partial_invalid': dict(block_address='2XX TEST AVE', latitude=90, longitude=1,
                                    has_invalid_coordinates=True, has_missing_coordinates=False),
            'matched': dict(latitude=1, longitude=1),
            'boundary': dict(latitude=0, longitude=1),
            'ambiguous': dict(latitude=1.75, longitude=1.75),
            'outside': dict(latitude=4, longitude=4),
            'null_unknown': dict(is_location_redacted=None, has_missing_coordinates=None, has_invalid_coordinates=None),
            'null_flags_pair': dict(latitude=1.2, longitude=1.2, is_location_redacted=None,
                                    has_missing_coordinates=None, has_invalid_coordinates=None),
            'null_flags_partial': dict(block_address='NULL FLAGS', is_location_redacted=None,
                                       has_missing_coordinates=None, has_invalid_coordinates=None),
            'null_redacted_partial': dict(neighborhood='NULL REDACTION', is_location_redacted=None),
            'valid_flag_missing': dict(latitude=1, longitude=1, has_missing_coordinates=True),
            'mixed_null_flags': dict(latitude=1.3, longitude=1.3,
                                     has_missing_coordinates=None, has_invalid_coordinates=None),
            'mixed_false_flags': dict(latitude=1.3, longitude=1.3,
                                      has_missing_coordinates=False, has_invalid_coordinates=False),
        }
        for source in ('crimes', 'arrests'):
            for key, attributes in cases.items():
                add(conn, source, key, **attributes)
            add(conn, source, 'block_repeat', **cases['block'])
            # El mismo lugar no se separa por un indicador de calidad distinto.
            add(conn, source, 'block_invalid', block_address='1XX TEST AVE', has_invalid_coordinates=True,
                has_missing_coordinates=False)
            add(conn, source, 'matched', **cases['matched'])  # Duplicado de origen, no del hecho.
        rebuild(conn)
        check(conn)
        expected_keys = sorted([*cases, 'block_repeat', 'block_invalid'])
        for model, key in [('crimes', 'offense_id'), ('arrest', 'arrest_number')]:
            assert conn.execute(f'select {key} from {model} order by 1').fetchall() == [(k,) for k in expected_keys]
            for event in ('unknown', 'invalid_unknown', 'police_only', 'null_unknown'):
                assert conn.execute(f'select address_id from {model} where {key} = ?', (event,)).fetchone() == ('UNKNOWN',)
            for event in ('hidden', 'hidden_empty'):
                assert conn.execute(f'select address_id from {model} where {key} = ?', (event,)).fetchone() == ('REDACTED',)
            assert conn.execute(f'select police_area_id from {model} where {key} = ?', ('police_only',)).fetchone() == ('POLICE',)
        assert conn.execute('select count(*) from full_address').fetchone() == (17,)
        assert conn.execute("select cp, cp_status from full_address where block_address='2XX TEST AVE'").fetchone() == (None, 'invalid_coordinates')
        assert conn.execute("select cp, cp_status from full_address where latitude=1 and longitude=1").fetchone() == ('98101', 'matched')
        assert conn.execute('''select has_missing_coordinates, cp, cp_status from full_address
                               where latitude=1 and longitude=1''').fetchone() == (1, '98101', 'matched')
        assert conn.execute('''select has_missing_coordinates, has_invalid_coordinates, cp, cp_status
                               from full_address where latitude=1.2 and longitude=1.2''').fetchone() == (0, 0, '98101', 'matched')
        assert conn.execute("""select has_missing_coordinates, has_invalid_coordinates, cp_status
                               from full_address where block_address='NULL FLAGS'""").fetchone() == (0, 0, 'missing_coordinates')
        assert set(conn.execute('select cp_status from full_address').fetchall()) == {
            (value,) for value in ('matched', 'redacted', 'missing_coordinates', 'invalid_coordinates', 'no_match', 'ambiguous', 'boundary')}
        print('PASS: identidad compartida, privacidad, parciales, grano, FK Silver/Gold y los siete estados postales')
        print('PASS: censura NULL, BOOLOR_AGG con entradas NULL/mixtas y par válido con indicador de ausencia agregado')

        initial = {name: rows(conn, name) for name in MODELS}
        rebuild(conn, incremental=True)
        assert initial == {name: rows(conn, name) for name in MODELS}
        for source in ('crimes', 'arrests'):
            add(conn, source, 'matched', day=2, is_location_redacted=True)
            add(conn, source, 'unknown', day=2, neighborhood='NEW AREA')
        rebuild(conn, incremental=True)
        check(conn)
        for model, key in [('crimes', 'offense_id'), ('arrest', 'arrest_number')]:
            assert conn.execute(f'select {key} from {model} order by 1').fetchall() == [(k,) for k in expected_keys]
            assert conn.execute(f'select address_id from {model} where {key} = ?', ('matched',)).fetchone() == ('REDACTED',)
        current = {name: rows(conn, name) for name in MODELS}
        rebuild(conn, incremental=True)
        assert current == {name: rows(conn, name) for name in MODELS}
        rebuild(conn)
        assert current == {name: rows(conn, name) for name in MODELS}
        print('PASS: delete+insert, transición a REDACTED/parcial, sin cambios de recuento, repetición y reconstrucción')

        for source in ('crimes', 'arrests'):
            add(conn, source, 'LATE', day=1, neighborhood='LATE AREA')
            add(conn, source, 'SAME_TIME', day=2, neighborhood='SAME TIME AREA')
        rebuild(conn, incremental=True)
        for name in KEYS:
            assert current[name] == rows(conn, name), name
        check(conn, allow_unprocessed=True)
        assert len(conn.execute(sql_file(conn, 'tests/singular/address_event_keys_preserved.sql')).fetchall()) == 4
        print('PASS: se conserva el corte incremental estricto para ingestas anteriores o iguales')

        before = conn.execute('select address_id from full_address order by 1').fetchall()
        conn.execute("update postal_codes set cp='98103' where cp='98101'")
        rebuild(conn, incremental=True)
        check(conn, allow_unprocessed=True)
        assert before == conn.execute('select address_id from full_address order by 1').fetchall()
        assert conn.execute('select cp from full_address where latitude=1 and longitude=1').fetchone() == ('98103',)
        for name in KEYS:
            assert current[name] == rows(conn, name)
        # La prueba detecta una FK existente, pero asignada al evento equivocado.
        conn.execute("update crimes set address_id='REDACTED' where offense_id='police_only'")
        assert conn.execute(sql_file(conn, 'tests/singular/address_event_assignments.sql')).fetchall()
        print('PASS: el mapa no cambia las claves y la prueba detecta referencias incorrectas')

    migration_check()


def migration_check():
    """Simula claves antiguas; no conecta ni modifica ningún destino externo."""
    with database() as conn:
        for source in ('crimes', 'arrests'):
            add(conn, source, 'unknown')
            add(conn, source, 'redacted', is_location_redacted=True)
            add(conn, source, 'partial', neighborhood='AREA')
            add(conn, source, 'valid', latitude=1, longitude=1)
        rebuild(conn)
        check(conn)
        original = {name: rows(conn, name) for name in MODELS}

        # Una clave obsoleta puede seguir teniendo forma de MD5: validar el formato no basta.
        for name in KEYS:
            conn.execute(f"update {name} set address_id=md5('legacy:' || address_id)")
        stale = {name: rows(conn, name) for name in KEYS}
        integrity_test = 'tests/singular/address_key_integrity.sql'
        assert len(conn.execute(sql_file(conn, integrity_test)).fetchall()) == 16
        rebuild(conn, incremental=True)
        assert stale == {name: rows(conn, name) for name in KEYS}
        assert len(conn.execute(sql_file(conn, integrity_test)).fetchall()) == 16

        # Reconstruir solo Silver no corrige Gold: las ingestas no han cambiado.
        for name in ('crimes', 'arrest'):
            build(conn, name)
        for name in ('fact_crimes', 'fact_arrests'):
            build(conn, name, incremental=True)
        assert len(conn.execute(sql_file(conn, integrity_test)).fetchall()) == 8
        for name in ('fact_crimes', 'fact_arrests'):
            build(conn, name)
        check(conn)
        assert original == {name: rows(conn, name) for name in MODELS}
        print('PASS: se detectan FK antiguas en Silver y Gold; el incremental no las repara; reconstrucción sin pérdida de claves ni filas')

        # Controles negativos: duplicación y pérdida simultánea en Silver y Gold.
        conn.execute('savepoint duplicate_address')
        conn.execute("insert into full_address select * from full_address where address_id='UNKNOWN'")
        assert conn.execute(sql_file(conn, integrity_test)).fetchall()
        conn.execute('rollback to duplicate_address')
        conn.execute('release duplicate_address')
        conn.execute("delete from crimes where offense_id='unknown'")
        conn.execute("delete from fact_crimes where offense_id='unknown'")
        assert len(conn.execute(sql_file(conn, 'tests/singular/address_event_keys_preserved.sql')).fetchall()) == 1
        print('PASS: las pruebas detectan direcciones duplicadas y pérdidas de eventos aunque Silver y Gold coincidan')


if __name__ == '__main__':
    main()
