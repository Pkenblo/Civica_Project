"""Regresión incremental de arrest_offenses sin conexiones a Snowflake.

python tests/integration/arrest_offenses_incremental_local_check.py
Requiere DuckDB, Jinja2 y sqlglot. Transpila el SQL real y simula delete+insert;
no sustituye una validación nativa de dbt/Snowflake.
"""

import hashlib

import duckdb
from jinja2 import Environment, StrictUndefined

from local_dbt_utils import dbt_utils_namespace
from offense_normalization_local_check import ROOT, fixture, translate


MODEL = ROOT / 'models/silver/arrests/arrest_offenses.sql'


def build(conn, incremental=False):
    config = {}
    template = (ROOT / 'macros/utils/after_max_ingested_at.sql').read_text() + MODEL.read_text()
    sql = Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: config.update(kwargs) or '', ref=lambda name: name,
        dbt_utils=dbt_utils_namespace(), this='arrest_offenses',
        is_incremental=lambda: incremental,
    )
    assert config == dict(materialized='incremental', incremental_strategy='delete+insert',
                          unique_key='arrest_offense_id', on_schema_change='fail'), config
    conn.execute('create table next_rows as ' + translate(sql))
    count = conn.execute('select count(*) from next_rows').fetchone()[0]
    if incremental:
        conn.execute('delete from arrest_offenses where arrest_offense_id in '
                     '(select arrest_offense_id from next_rows)')
        conn.execute('insert into arrest_offenses select * from next_rows')
    else:
        conn.execute('create or replace table arrest_offenses as select * from next_rows')
    conn.execute('drop table next_rows')
    assert conn.execute('select count(*) = count(distinct arrest_offense_id) '
                        'from arrest_offenses').fetchone()[0]
    return count


def snapshot(conn):
    return conn.execute('select * from arrest_offenses order by arrest_offense_id').fetchall()


def main():
    with duckdb.connect() as conn:
        rows = [
            dict(arrest_number='A1', offense_type='CHARGE A', nibrs_description='MATCHED'),
            dict(arrest_number='A1', offense_type='CHARGE B', nibrs_description=None),
            dict(arrest_number='A1', offense_type='CHARGE C', nibrs_description='AMBIGUOUS'),
            dict(arrest_number='A1', offense_type=None, nibrs_description='UNKNOWN'),
            dict(arrest_number='A1', offense_type=None, nibrs_description=None),
            dict(arrest_number='A2', offense_type='CHARGE A', nibrs_description='MATCHED'),
        ]
        for row in rows:
            row['ingested_at'] = '2026-01-02'
        fixture(conn, 'stg_arrests', rows + [rows[0]])
        fixture(conn, 'arrest', [dict(arrest_number='A1')])
        fixture(conn, 'offense_types', [
            dict(offense_type=f'CHARGE {c}', offense_type_id=hashlib.md5(f'CHARGE {c}'.encode()).hexdigest())
            for c in 'ABCDE'
        ])
        fixture(conn, 'nibrs', [
            dict(nibrs_key='M1', offense_description='MATCHED'),
            dict(nibrs_key='N1', offense_description='AMBIGUOUS'),
            dict(nibrs_key='N2', offense_description='AMBIGUOUS'),
        ])
        assert build(conn) == 4
        assert dict(conn.execute('select nibrs_match_status, count(*) from arrest_offenses '
                                 'group by 1').fetchall()) == {
            'matched': 1, 'missing': 1, 'ambiguous': 1, 'unmatched': 1,
        }
        assert build(conn, True) == 0
        print('PASS: carga inicial, estados NIBRS, duplicados, cargos vacíos y repetición')

        # El corte global omite ingestas antiguas y empates, incluso para cargos nuevos.
        conn.execute("""insert into stg_arrests values
            ('A1', 'CHARGE D', null, '2026-01-01'),
            ('A1', 'CHARGE E', null, '2026-01-02')""")
        assert build(conn, True) == 0
        conn.execute("insert into arrest values ('A2')")
        assert build(conn, True) == 0
        conn.execute("""insert into stg_arrests values
            ('A1', 'CHARGE D', null, '2026-01-03'),
            ('A1', 'CHARGE D', null, '2026-01-04'),
            ('A2', 'CHARGE A', 'MATCHED', '2026-01-04'),
            ('A1', 'CHARGE A', 'MATCHED', '2026-01-04'),
            ('A1', 'CHARGE E', null, null)""")
        assert build(conn, True) == 3
        assert len(snapshot(conn)) == 6
        assert conn.execute("""select ingested_at = timestamp '2026-01-04'
            from arrest_offenses where offense_type_id = md5('CHARGE D')""").fetchone()[0]
        assert build(conn, True) == 0
        print('PASS: corte global estricto, altas, actualización y mayor ingesta por cargo')

        original_ids = [row[0] for row in snapshot(conn)]
        # Un cambio NIBRS sin nueva ingesta no recalcula los cargos anteriores.
        conn.execute("insert into nibrs values ('M2', 'MATCHED')")
        assert build(conn, True) == 0
        conn.execute("""insert into stg_arrests values
            ('A1', 'CHARGE A', 'MATCHED', '2026-01-05'),
            ('A2', 'CHARGE A', 'MATCHED', '2026-01-05')""")
        assert build(conn, True) == 2
        assert conn.execute("""select count(*) from arrest_offenses
            where offense_type_id = md5('CHARGE A') and nibrs_key is null
              and nibrs_match_status = 'ambiguous'
              and unresolved_nibrs_description = 'MATCHED'""").fetchone()[0] == 2
        conn.execute("delete from nibrs where offense_description = 'MATCHED'")
        assert build(conn, True) == 0
        conn.execute("""insert into stg_arrests values
            ('A1', 'CHARGE A', 'MATCHED', '2026-01-06'),
            ('A2', 'CHARGE A', 'MATCHED', '2026-01-06')""")
        assert build(conn, True) == 2
        assert conn.execute("""select count(*) from arrest_offenses
            where offense_type_id = md5('CHARGE A') and nibrs_match_status = 'unmatched'
              and nibrs_key is null and unresolved_nibrs_description = 'MATCHED'""").fetchone()[0] == 2
        conn.execute("insert into nibrs values ('M3', 'MATCHED')")
        conn.execute("""insert into stg_arrests values
            ('A1', 'CHARGE A', 'MATCHED', '2026-01-07'),
            ('A2', 'CHARGE A', 'MATCHED', '2026-01-07')""")
        assert build(conn, True) == 2
        assert conn.execute("""select count(*) from arrest_offenses
            where offense_type_id = md5('CHARGE A') and nibrs_key = 'M3'
              and nibrs_match_status = 'matched'
              and unresolved_nibrs_description is null""").fetchone()[0] == 2
        assert [row[0] for row in snapshot(conn)] == original_ids
        assert build(conn, True) == 0
        print('PASS: resolución NIBRS solo con nueva ingesta, nulos y claves estables')

        expected = snapshot(conn)
        # El full refresh recupera el cargo E omitido por el corte.
        assert build(conn) == 7
        assert all(row in snapshot(conn) for row in expected)
        for name in ('arrest_offenses_preserved', 'arrest_nibrs_resolution',
                     'offense_type_references_resolved'):
            sql = Environment(undefined=StrictUndefined).from_string(
                (ROOT / f'tests/singular/{name}.sql').read_text()
            ).render(ref=lambda model: model, dbt_utils=dbt_utils_namespace())
            assert not conn.execute(translate(sql)).fetchall(), name
        # Omitir evidencia no es una señal de baja: no se borran otros cargos.
        expected = snapshot(conn)
        conn.execute("delete from stg_arrests where offense_type = 'CHARGE B'")
        assert build(conn, True) == 0
        assert snapshot(conn) == expected
        conn.execute('delete from arrest_offenses')
        assert build(conn, True) == 0
        assert build(conn) == 6
        print('PASS: tests singulares, full refresh, destino vacío y ausencia de bajas')


if __name__ == '__main__':
    main()
