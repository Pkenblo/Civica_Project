"""Regresión de los incrementales Gold afectados por los cambios de Silver.

python tests/integration/gold_report_updates_local_check.py
Requiere DuckDB, Jinja2, PyYAML y sqlglot. No escribe en Snowflake.
"""

import duckdb
from jinja2 import Environment, StrictUndefined
import yaml

from gold_incremental_local_check import ROOT, build, offense_tests, translate


def report_tests(conn):
    conn.execute('''create table reports (
        report_id varchar, report_number varchar, report_date_time timestamp, ingested_at timestamp)''')
    conn.execute("""insert into reports values
        ('R1', '1', '2020-01-02', '2026-01-02'),
        ('R2', '2', null, '2026-01-02')""")
    assert build(conn, 'dim_report') == 2
    assert build(conn, 'dim_report', True) == 0
    conn.execute("update reports set report_date_time = null, ingested_at = '2026-01-03' where report_id = 'R1'")
    conn.execute("insert into reports values ('R3', '3', '2020-01-03', '2026-01-03')")
    assert build(conn, 'dim_report', True) == 2
    assert not conn.execute('select * from reports except select * from dim_report').fetchall()
    assert conn.execute('select count(*), count(distinct report_id) from dim_report').fetchone() == (3, 3)
    assert build(conn, 'dim_report', True) == 0
    conn.execute("""insert into reports values
        ('OLD', 'OLD', null, '2026-01-01'), ('TIE', 'TIE', null, '2026-01-03')""")
    assert build(conn, 'dim_report', True) == 0
    assert build(conn, 'dim_report') == 5
    conn.execute('delete from dim_report')
    assert build(conn, 'dim_report', True) == 0
    assert build(conn, 'dim_report') == 5
    print('PASS: dim_report, altas, nulos, corte estricto, repetición y full refresh')


def assert_crime_dates(conn):
    sql = Environment(undefined=StrictUndefined).from_string(
        (ROOT / 'tests/singular/gold/gold_crime_roles.sql').read_text()
    ).render(ref=lambda model: model)
    assert not conn.execute(translate(sql)).fetchall()
    assert not conn.execute('''select * from fact_crimes where
        report_date is distinct from cast(report_date_time as date)
        or report_date_key is distinct from cast(strftime(report_date_time, '%Y%m%d') as integer)''').fetchall()
    assert not conn.execute('''select f.crime_id from fact_crimes f
        join crimes c using (crime_id) where f.ingested_at is distinct from c.ingested_at''').fetchall()
    assert conn.execute('select count(*) = count(distinct crime_id) from fact_crimes').fetchone()[0]


def crime_tests(conn):
    conn.execute('''create table crimes (
        crime_id varchar, report_id varchar, offense_id varchar, nibrs_key varchar,
        address_id varchar, police_area_id varchar, offense_category_id varchar,
        offense_date timestamp, ingested_at timestamp)''')
    conn.execute("""insert into crimes values
        ('C1', 'R1', 'O1', null, null, null, null, '2020-01-01', '2026-01-02'),
        ('C2', 'R1', 'O2', null, null, null, null, '2020-01-01', '2026-01-02'),
        ('C3', 'R2', 'O3', null, null, null, null, '2020-01-01', '2026-01-02')""")
    conn.execute('''create table reports (
        report_id varchar, report_number varchar, report_date_time timestamp, ingested_at timestamp)''')
    conn.execute("""insert into reports values
        ('R1', '1', '2020-01-02', '2026-01-02'),
        ('R2', '2', '2020-01-01', '2026-01-02')""")
    conn.execute('create table dim_date (full_date date, date_key integer)')
    conn.execute("""insert into dim_date values
        ('2020-01-01', 20200101), ('2020-01-02', 20200102), ('2020-01-03', 20200103)""")
    assert build(conn, 'dim_report') == 2
    assert build(conn, 'fact_crimes') == 3
    assert build(conn, 'fact_crimes', True) == 0
    unchanged = conn.execute("select * from fact_crimes where crime_id = 'C3'").fetchall()

    # Dos delitos comparten informe: solo uno recibe una nueva versión en Silver.
    conn.execute("update reports set report_date_time = '2020-01-03', ingested_at = '2026-01-03' where report_id = 'R1'")
    conn.execute("update crimes set ingested_at = '2026-01-03' where crime_id = 'C2'")
    assert build(conn, 'dim_report', True) == 1
    assert build(conn, 'fact_crimes', True) == 2
    assert_crime_dates(conn)
    assert conn.execute("select * from fact_crimes where crime_id = 'C3'").fetchall() == unchanged
    assert build(conn, 'fact_crimes', True) == 0

    # Solo cambia el informe, primero a NULL y después a una fecha informada.
    for timestamp, date in [('2026-01-04', None), ('2026-01-05', '2020-01-02')]:
        conn.execute("update reports set report_date_time = ?, ingested_at = ? where report_id = 'R1'", [date, timestamp])
        assert build(conn, 'dim_report', True) == 1
        assert build(conn, 'fact_crimes', True) == 2
        assert_crime_dates(conn)
        assert build(conn, 'fact_crimes', True) == 0

    # La ingesta del informe no adelanta el cursor del delito (sigue en el día 3).
    conn.execute("insert into crimes values ('C4', 'R2', 'O4', null, null, null, null, '2020-01-01', '2026-01-04')")
    assert build(conn, 'fact_crimes', True) == 1
    assert_crime_dates(conn)
    before = conn.execute('select * from fact_crimes order by crime_id').fetchall()
    assert build(conn, 'fact_crimes') == 4
    assert conn.execute('select * from fact_crimes order by crime_id').fetchall() == before
    print('PASS: fact_crimes, informe compartido, correcciones sin nueva ingesta, nulos y cursor intacto')


def config_tests():
    gold = yaml.safe_load((ROOT / 'dbt_project.yml').read_text())['models']['my_new_project']['gold']
    for folder, name in [('dimensions', 'dim_report'), ('dimensions', 'dim_offense_types'), ('facts', 'fact_crimes')]:
        config = gold[folder][name]
        assert config['+materialized'] == 'incremental'
        assert config['+incremental_strategy'] == 'delete+insert'
        assert config['+on_schema_change'] == 'fail'


if __name__ == '__main__':
    config_tests()
    for test in (offense_tests, report_tests, crime_tests):
        with duckdb.connect() as conn:
            test(conn)
