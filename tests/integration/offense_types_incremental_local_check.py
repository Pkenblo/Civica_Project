"""Regresión local del cursor de offense_types, sin escribir en Snowflake.

python tests/integration/offense_types_incremental_local_check.py
Requiere DuckDB, Jinja2 y sqlglot. Transpila el SQL real y simula delete+insert.
"""

import duckdb
from jinja2 import Environment, StrictUndefined

from local_dbt_utils import dbt_utils_namespace
from offense_normalization_local_check import ROOT, assert_catalog_schema, fixture, translate


def build(conn, incremental=False):
    config = {}
    template = (ROOT / 'macros/utils/after_max_ingested_at.sql').read_text()
    template += (ROOT / 'models/silver/arrests/offense_types.sql').read_text()
    sql = Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: config.update(kwargs) or '', ref=lambda name: name,
        this='offense_types', is_incremental=lambda: incremental,
        dbt_utils=dbt_utils_namespace(),
    )
    assert config == dict(materialized='incremental', incremental_strategy='delete+insert',
                          unique_key='offense_type_id', on_schema_change='fail'), config
    conn.execute('create table next_rows as ' + translate(sql))
    count = conn.execute('select count(*) from next_rows').fetchone()[0]
    if incremental:
        conn.execute('delete from offense_types where offense_type_id in '
                     '(select offense_type_id from next_rows)')
        conn.execute('insert into offense_types select * from next_rows')
    else:
        conn.execute('create or replace table offense_types as select * from next_rows')
    conn.execute('drop table next_rows')
    assert_catalog_schema(conn, 'offense_types')
    assert conn.execute('select count(*) = count(distinct offense_type_id) '
                        'from offense_types').fetchone()[0]
    return count


def snapshot(conn):
    return conn.execute('select * from offense_types order by offense_type_id').fetchall()


def main():
    with duckdb.connect() as conn:
        fixture(conn, 'stg_arrests', [
            dict(offense_type='DOC DETAINER', offense_type_original='Doc Detainer',
                 ingested_at='2026-01-01', source_file='a.csv', batch_id='1'),
            dict(offense_type='DOC DETAINER', offense_type_original='DOC DETAINER',
                 ingested_at='2026-01-02', source_file='b.csv', batch_id='2'),
            dict(offense_type='RCW - 9A.36.041 | ASSAULT',
                 offense_type_original='RCW - 9A.36.041 | ASSAULT',
                 ingested_at='2026-01-02', source_file='b.csv', batch_id='2'),
        ])
        assert build(conn) == 2
        assert conn.execute("""select offense_type_id = md5(offense_type),
            offense_type_original_values, ingested_at = timestamp '2026-01-02'
            from offense_types where offense_type = 'DOC DETAINER'""").fetchone() == (
                True, ['DOC DETAINER', 'Doc Detainer'], True)
        assert conn.execute("select legal_code from offense_types where parse_status = 'parsed'").fetchall() == [('9A.36.041',)]
        assert build(conn, True) == 0
        print('PASS: carga inicial, parser, clave estable, variantes y repetición')

        conn.execute("""insert into stg_arrests values
            ('OLD', 'OLD', '2026-01-01', 'c.csv', '3'),
            ('TIE', 'TIE', '2026-01-02', 'c.csv', '3'),
            ('NO DATE', 'NO DATE', null, 'c.csv', '3'),
            (null, null, '2026-01-10', 'c.csv', '3')""")
        assert build(conn, True) == 0
        previous = snapshot(conn)
        conn.execute("""insert into stg_arrests values
            ('DOC DETAINER', 'doc detainer', '2026-01-03', 'c.csv', '3'),
            ('DOC DETAINER', 'Doc detainer', '2026-01-04', 'd.csv', '4'),
            ('OUTSIDE AGENCY -- FELONY WARRANT', 'OUTSIDE AGENCY -- FELONY WARRANT',
             '2026-01-04', 'd.csv', '4')""")
        assert build(conn, True) == 2
        assert conn.execute("""select offense_type_original_values,
            ingested_at = timestamp '2026-01-04'
            from offense_types where offense_type = 'DOC DETAINER'""").fetchone() == (
                ['DOC DETAINER', 'Doc Detainer', 'Doc detainer', 'doc detainer'], True)
        assert all(row in snapshot(conn) for row in previous if row[1] != 'DOC DETAINER')
        assert build(conn, True) == 0
        print('PASS: corte estricto, fechas nulas, altas y actualización sin perder variantes')

        # Una omisión no retira el tipo; full refresh recupera las claves tardías.
        conn.execute('create table backup_staging as select * from stg_arrests')
        conn.execute("delete from stg_arrests where offense_type like 'RCW%'")
        before = snapshot(conn)
        assert build(conn, True) == 0
        assert snapshot(conn) == before
        conn.execute('create or replace table stg_arrests as select * from backup_staging')
        assert build(conn) == 5
        assert all(row in snapshot(conn) for row in before)
        conn.execute('delete from offense_types')
        assert build(conn, True) == 0
        assert build(conn) == 5
        print('PASS: ausencia de bajas, recuperación de ingestas tardías y destino vacío')


if __name__ == '__main__':
    main()
