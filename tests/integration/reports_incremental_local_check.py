"""Regresión incremental de reports sin conexiones a Snowflake.

python tests/integration/reports_incremental_local_check.py
Requiere DuckDB, Jinja2 y sqlglot. Transpila el SQL real y simula delete+insert.
"""

import duckdb
from jinja2 import Environment, StrictUndefined

from local_dbt_utils import dbt_utils_namespace
from offense_normalization_local_check import ROOT, translate


def build(conn, incremental=False):
    config = {}
    template = (ROOT / 'macros/utils/after_max_ingested_at.sql').read_text()
    template += (ROOT / 'models/silver/reports/reports.sql').read_text()
    sql = Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: config.update(kwargs) or '', ref=lambda name: name,
        this='reports', is_incremental=lambda: incremental,
        dbt_utils=dbt_utils_namespace(),
    )
    assert config == dict(materialized='incremental', incremental_strategy='delete+insert',
                          unique_key='report_id', on_schema_change='fail'), config
    conn.execute('create table next_rows as ' + translate(sql))
    count = conn.execute('select count(*) from next_rows').fetchone()[0]
    if incremental:
        conn.execute('delete from reports where report_id in (select report_id from next_rows)')
        conn.execute('insert into reports select * from next_rows')
    else:
        conn.execute('create or replace table reports as select * from next_rows')
    conn.execute('drop table next_rows')
    assert conn.execute('''select count(*) = count(distinct report_id)
        and count(*) = count(distinct report_number)
        and count(*) = count(ingested_at) from reports''').fetchone()[0]
    assert not conn.execute('select * from reports where report_id <> md5(report_number)').fetchall()
    return count


def snapshot(conn):
    return conn.execute('select * from reports order by report_number').fetchall()


def main():
    with duckdb.connect() as conn:
        conn.execute('''create table stg_crimes (
            report_number varchar, report_date_time timestamp, ingested_at timestamp,
            source_file varchar, batch_id varchar)''')
        conn.execute('''create table stg_arrests (report_number varchar, ingested_at timestamp)''')
        conn.execute("""insert into stg_crimes values
            ('C', '2025-01-01', '2026-01-02', 'a.csv', '1'),
            ('BOTH', '2025-02-01', '2026-01-02', 'a.csv', '1'),
            ('BOTH', '2025-02-02', '2026-01-02', 'z.csv', '1'),
            ('NO DATE', '2025-01-01', null, 'a.csv', '1'),
            (null, '2025-01-01', '2026-01-20', 'a.csv', '1')""")
        conn.execute("""insert into stg_arrests values
            ('A', '2026-01-03'), ('BOTH', '2026-01-03'),
            ('NO DATE', null), (null, '2026-01-20')""")
        assert build(conn) == 3
        assert conn.execute("select report_date_time from reports where report_number = 'A'").fetchone() == (None,)
        assert conn.execute("""select report_date_time = timestamp '2025-02-02',
            ingested_at = timestamp '2026-01-03' from reports where report_number = 'BOTH'""").fetchone() == (True, True)
        assert build(conn, True) == 0
        print('PASS: ambas fuentes, deduplicación, desempates, claves, fechas nulas y repetición')

        conn.execute("""insert into stg_crimes values
            ('C OLD', '2025-01-01', '2026-01-02', 'a.csv', '1'),
            ('C TIE', '2025-01-01', '2026-01-03', 'a.csv', '1')""")
        conn.execute("""insert into stg_arrests values
            ('A OLD', '2026-01-02'), ('A TIE', '2026-01-03')""")
        assert build(conn, True) == 0
        conn.execute("insert into stg_arrests values ('BOTH', '2026-01-04'), ('A', '2026-01-04')")
        assert build(conn, True) == 2
        assert conn.execute("""select report_date_time = timestamp '2025-02-02',
            ingested_at = timestamp '2026-01-04' from reports where report_number = 'BOTH'""").fetchone() == (True, True)
        assert conn.execute("select report_date_time from reports where report_number = 'A'").fetchone() == (None,)
        print('PASS: corte global compartido y conservación de la fecha ante nuevas detenciones')

        unchanged = conn.execute("select * from reports where report_number = 'C'").fetchall()
        conn.execute("""insert into stg_crimes values
            ('BOTH', null, '2026-01-05', 'a.csv', '2'),
            ('A', '2025-03-01', '2026-01-05', 'a.csv', '2'),
            ('NEW', '2025-04-01', '2026-01-04', 'a.csv', '2'),
            ('NEW', '2025-04-02', '2026-01-05', 'a.csv', '2'),
            ('NEW', '2025-04-02', '2026-01-05', 'a.csv', '2')""")
        assert build(conn, True) == 3
        assert conn.execute("select report_date_time from reports where report_number = 'BOTH'").fetchone() == (None,)
        assert conn.execute("select report_date_time = timestamp '2025-03-01' from reports where report_number = 'A'").fetchone()[0]
        assert conn.execute("select report_date_time = timestamp '2025-04-02' from reports where report_number = 'NEW'").fetchone()[0]
        assert conn.execute("select * from reports where report_number = 'C'").fetchall() == unchanged
        assert build(conn, True) == 0
        print('PASS: altas, actualización completa con nulos y detención que recibe fecha de delitos')

        expected = snapshot(conn)
        conn.execute('create table backup_crimes as select * from stg_crimes')
        conn.execute("delete from stg_crimes where report_number = 'C'")
        assert build(conn, True) == 0
        assert snapshot(conn) == expected
        conn.execute('create or replace table stg_crimes as select * from backup_crimes')
        assert build(conn) == 8
        assert all(row in snapshot(conn) for row in expected)
        conn.execute('delete from reports')
        assert build(conn, True) == 0
        assert build(conn) == 8
        print('PASS: ausencia de bajas, recuperación de ingestas tardías y destino vacío')


if __name__ == '__main__':
    main()
