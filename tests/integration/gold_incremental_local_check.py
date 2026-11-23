"""Regresión local de los incrementales Gold, sin conexiones a Snowflake.

python tests/integration/gold_incremental_local_check.py
Requiere DuckDB, Jinja2, PyYAML y sqlglot. Ejecuta el SQL real traducido;
solo sustituye la generación del calendario de dbt_date por fechas de prueba.
"""

from datetime import date, timedelta
from pathlib import Path
from types import SimpleNamespace

import duckdb
from jinja2 import Environment, StrictUndefined
import sqlglot
from sqlglot import exp
import yaml


ROOT = Path(__file__).resolve().parents[2]
KEYS = {'dim_subject': 'subject_key', 'dim_offense_types': 'offense_type_id',
        'dim_report': 'report_id', 'fact_crimes': 'crime_id', 'dim_date': 'date_key'}


def translate(sql):
    # sqlglot no traduce los formatos de TO_CHAR para expresiones sin tipo inferido.
    formats = {'YYYY-MM-DD': '%Y-%m-%d', 'YYYYMMDD': '%Y%m%d', 'YYYY-MM': '%Y-%m'}

    def to_char(node):
        if isinstance(node, exp.ToChar):
            return exp.Anonymous(this='strftime', expressions=[
                node.this.copy(), exp.Literal.string(formats[node.args['format'].this])])
        return node

    return sqlglot.parse_one(sql, read='snowflake').transform(to_char).sql(dialect='duckdb')


def calendar(first, end):
    rows = []
    current = date.fromisoformat(first)
    while current < date.fromisoformat(end):
        iso = current.isocalendar()
        rows.append(f"(date '{current}', {current.year}, {(current.month - 1) // 3 + 1}, "
                    f"{current.month}, '{current:%b}', {iso.week}, {current.day}, "
                    f"{iso.weekday}, '{current:%a}')")
        current += timedelta(days=1)
    return 'select * from (values ' + ', '.join(rows) + ''') as dates(
        date_day, year_number, quarter_of_year, month_of_year, month_name_short,
        iso_week_of_year, day_of_month, day_of_week_iso, day_of_week_name_short)'''


def render(conn, name, incremental):
    config = {}
    template = (ROOT / 'macros/utils/after_max_ingested_at.sql').read_text()
    folder = 'facts' if name == 'fact_crimes' else 'dimensions'
    template += (ROOT / f'models/gold/{folder}/{name}.sql').read_text()
    return Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: config.update(kwargs) or '',
        ref=lambda model: model, this=name, is_incremental=lambda: incremental,
        execute=True, run_query=lambda sql: SimpleNamespace(rows=conn.execute(translate(sql)).fetchall()),
        dbt_date=SimpleNamespace(get_date_dimension=calendar),
    ), config


def build(conn, name, incremental=False):
    sql, config = render(conn, name, incremental)
    assert config['unique_key'] == KEYS[name], (name, config)
    conn.execute('create table next_rows as ' + translate(sql))
    count = conn.execute('select count(*) from next_rows').fetchone()[0]
    if incremental:
        key = KEYS[name]
        conn.execute(f'delete from {name} where {key} in (select {key} from next_rows)')
        conn.execute(f'insert into {name} select * from next_rows')
        conn.execute('drop table next_rows')
    else:
        conn.execute(f'create or replace table {name} as select * from next_rows')
        conn.execute('drop table next_rows')
    return count


def subject_tests(conn):
    conn.execute('''create table subject (
        subject_key varchar, sk_person varchar, subject_gender varchar,
        subject_race varchar, ingested_at timestamp)''')
    conn.execute("insert into subject values ('S1', '1', 'M', null, '2026-01-02')")
    assert build(conn, 'dim_subject') == 1
    assert build(conn, 'dim_subject', True) == 0
    conn.execute("update subject set subject_gender = null, ingested_at = '2026-01-03' where subject_key = 'S1'")
    conn.execute("insert into subject values ('S2', '2', 'F', null, '2026-01-03')")
    # El corte estricto coincide con Silver: ni ingestas anteriores ni empates pasan.
    conn.execute("insert into subject values ('OLD', '3', null, null, '2026-01-01')")
    conn.execute("insert into subject values ('TIE', '4', null, null, '2026-01-02')")
    assert build(conn, 'dim_subject', True) == 2
    assert conn.execute('select subject_key, subject_gender from dim_subject order by 1').fetchall() == [
        ('S1', None), ('S2', 'F')]
    assert build(conn, 'dim_subject', True) == 0
    assert build(conn, 'dim_subject') == 4
    conn.execute('delete from dim_subject')
    assert build(conn, 'dim_subject', True) == 0
    assert build(conn, 'dim_subject') == 4
    print('PASS: sujetos, altas, actualizaciones, nulos, corte estricto, repetición y full refresh')


def offense_tests(conn):
    conn.execute('''create table offense_types (
        offense_type_id varchar, offense_type varchar, offense_type_original_values varchar[],
        legal_source varchar, legal_code varchar, secondary_legal_source varchar,
        secondary_legal_code varchar, external_code varchar, offense_description varchar,
        offense_category varchar, parse_status varchar, ingested_at timestamp)''')
    conn.execute("""insert into offense_types values (
        'O1', 'DOC DETAINER', ['DOC DETAINER'], null, null, null, null, null,
         'DOC DETAINER', null, 'administrative', '2026-01-02')""")
    assert build(conn, 'dim_offense_types') == 1
    assert build(conn, 'dim_offense_types', True) == 0
    conn.execute("""update offense_types set offense_type_original_values = ['DOC DETAINER', 'Doc Detainer'],
                    offense_category = 'UPDATED', ingested_at = '2026-01-03'
                    where offense_type_id = 'O1'""")
    conn.execute("""insert into offense_types values (
        'O2', 'OUTSIDE AGENCY -- FELONY WARRANT', ['Outside Agency -- Felony Warrant'],
         null, null, null, null, null, 'OUTSIDE AGENCY -- FELONY WARRANT', null, 'administrative', '2026-01-03')""")
    assert build(conn, 'dim_offense_types', True) == 2
    assert not conn.execute('select * from offense_types except select * from dim_offense_types').fetchall()
    assert conn.execute('select count(*), count(distinct offense_type_id) from dim_offense_types').fetchone() == (2, 2)
    assert build(conn, 'dim_offense_types', True) == 0
    conn.execute("update offense_types set offense_category = null, ingested_at = '2026-01-04' where offense_type_id = 'O1'")
    assert build(conn, 'dim_offense_types', True) == 1
    for key, timestamp in [('OLD', '2026-01-02'), ('TIE', '2026-01-04')]:
        conn.execute("""insert into offense_types values (?, ?, [?], null, null, null,
            null, null, ?, null, 'review_required', ?)""", [key, key, key, key, timestamp])
    assert build(conn, 'dim_offense_types', True) == 0
    assert build(conn, 'dim_offense_types') == 4
    conn.execute('delete from dim_offense_types')
    assert build(conn, 'dim_offense_types', True) == 0
    assert build(conn, 'dim_offense_types') == 4
    print('PASS: catálogo con cursor, corte estricto, arrays, correcciones, nulos y repetición')


def calendar_tests(conn):
    conn.execute('create table crimes (offense_date timestamp)')
    conn.execute('create table reports (report_date_time timestamp)')
    conn.execute('create table arrest (arrest_occurred_date_time timestamp, arrest_reported_date_time timestamp)')
    conn.execute('create table licenses (license_issue_date date)')
    assert build(conn, 'dim_date') == 0
    assert build(conn, 'dim_date', True) == 0
    conn.execute("insert into crimes values ('2026-01-02')")
    conn.execute("insert into licenses values ('2026-01-04')")
    assert build(conn, 'dim_date', True) == 3
    assert build(conn, 'dim_date', True) == 0
    conn.execute("insert into reports values ('2025-12-31')")
    conn.execute("insert into arrest values ('2026-01-06', '2026-01-05')")
    conn.execute("delete from dim_date where full_date = '2026-01-03'")
    assert build(conn, 'dim_date', True) == 5
    assert conn.execute('select count(*), count(distinct date_key) from dim_date').fetchone() == (7, 7)
    sql = (ROOT / 'tests/singular/gold/date_calendar_consistency.sql').read_text()
    sql = Environment(undefined=StrictUndefined).from_string(sql).render(ref=lambda model: model)
    assert not conn.execute(translate(sql)).fetchall()
    before = conn.execute('select * from dim_date order by date_key').fetchall()
    assert build(conn, 'dim_date') == 7
    assert conn.execute('select * from dim_date order by date_key').fetchall() == before
    for name in ('crimes', 'reports', 'arrest', 'licenses'):
        conn.execute(f'delete from {name}')
    assert build(conn, 'dim_date', True) == 0
    assert build(conn, 'dim_date') == 0
    print('PASS: calendario vacío, extensión en ambos extremos, huecos, atributos y full refresh')


def config_tests():
    gold = yaml.safe_load((ROOT / 'dbt_project.yml').read_text())['models']['my_new_project']['gold']
    expected = {
        'dimensions': ['dim_date', 'dim_subject', 'dim_offense_types', 'dim_report', 'dim_licenses'],
        'facts': ['fact_crimes', 'fact_arrests'],
    }
    for folder, names in expected.items():
        for name in names:
            config = gold[folder][name]
            assert config['+materialized'] == 'incremental', name
            assert config['+incremental_strategy'] == 'delete+insert', name
            assert config['+on_schema_change'] == 'fail', name
            assert 'is_incremental()' in (ROOT / f'models/gold/{folder}/{name}.sql').read_text(), name
    print('PASS: configuración incremental de los modelos Gold')


if __name__ == '__main__':
    config_tests()
    with duckdb.connect() as conn:
        subject_tests(conn)
        offense_tests(conn)
        calendar_tests(conn)
