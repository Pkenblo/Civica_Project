"""Regresión SQLite de la clasificación de delitos, sin conexión a Snowflake.

python tests/integration/offense_categories_local_check.py
Requiere Jinja2, PyYAML y sqlglot. Traduce el SQL real y emula sus funciones
de hash; no valida las conversiones exactas ni el motor de Snowflake.
"""

from collections import Counter
import hashlib
import json
from pathlib import Path
import sqlite3

from jinja2 import Environment, StrictUndefined
import sqlglot
from sqlglot.optimizer.qualify import qualify
import yaml

from local_dbt_utils import dbt_utils_namespace


ROOT = Path(__file__).resolve().parents[2]
MODELS = {
    'offense_categories': 'models/silver/crimes/offense_categories.sql',
    'crimes': 'models/silver/crimes/crimes.sql',
    'dim_offense_classification': 'models/gold/dimensions/dim_offense_classification.sql',
    'fact_crimes': 'models/gold/facts/fact_crimes.sql',
}


def database():
    conn = sqlite3.connect(':memory:')
    conn.create_function('MD5', 1, lambda value: hashlib.md5(value.encode()).hexdigest() if value is not None else None)
    conn.create_function('ARRAY', -1, lambda *values: json.dumps(values, separators=(',', ':')))
    conn.create_function('JSON_FORMAT', 1, lambda value: value)
    conn.create_function('EQUAL_NULL', 2, lambda left, right: left == right)
    return conn


def sql_file(conn, path, incremental=False):
    template = (ROOT / 'macros/utils/address_id.sql').read_text() + (ROOT / path).read_text()
    rendered = Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: '', ref=lambda name: name, is_incremental=lambda: incremental,
        after_max_ingested_at=lambda column: f'{column} > (select max(ingested_at) from crimes)',
        dbt_utils=dbt_utils_namespace(),
    )
    expression = sqlglot.parse_one(rendered, read='snowflake')
    if path == MODELS['crimes']:
        # SQLite no entiende SELECT * EXCLUDE: expandirlo con las columnas del fixture.
        schema = {name: {col[1]: col[2] or 'TEXT' for col in conn.execute(f'pragma table_info({name})')}
                  for name, in conn.execute("select name from sqlite_master where type = 'table'").fetchall()}
        expression = qualify(expression, dialect='snowflake', schema=schema)
    return expression.sql(dialect='sqlite')


def build(conn, name, incremental=False):
    conn.execute(f'create table next_rows as {sql_file(conn, MODELS[name], incremental)}')
    if incremental:
        conn.execute(f'delete from {name} where crime_id in (select crime_id from next_rows)')
        conn.execute(f'insert into {name} select * from next_rows')
        conn.execute('drop table next_rows')
    else:
        conn.execute(f'drop table if exists {name}')
        conn.execute(f'alter table next_rows rename to {name}')


def unit_tests():
    for path in ['models/gold/dimensions/_offense_classification_unit_tests.yml']:
        for test in yaml.safe_load((ROOT / path).read_text())['unit_tests']:
            with database() as conn:
                for given in test['given']:
                    name = given['input'].split("'")[1]
                    columns = list(given['rows'][0])
                    conn.execute(f'create table {name} ({", ".join(col + " text" for col in columns)})')
                    conn.executemany(f'insert into {name} values ({", ".join("?" for _ in columns)})',
                                     [[row.get(col) for col in columns] for row in given['rows']])
                build(conn, test['model'])
                expected = test['expect']['rows']
                if expected:
                    columns = list(expected[0])
                    actual = conn.execute(f'select {", ".join(columns)} from {test["model"]}').fetchall()
                    assert Counter(actual) == Counter(tuple(row[col] for col in columns) for row in expected), test['name']
                else:
                    assert conn.execute(f'select count(*) from {test["model"]}').fetchone() == (0,), test['name']
                print('PASS:', test['name'])


def classification_tests(conn):
    for name, path in [('offense_categories', 'models/silver/crimes/_crimes.yml'),
                       ('dim_offense_classification', 'models/gold/dimensions/_dimensions.yml')]:
        spec = next(model for model in yaml.safe_load((ROOT / path).read_text())['models'] if model['name'] == name)
        key = spec['columns'][0]['name']
        assert conn.execute(f'select count(*) = count(distinct {key}) from {name}').fetchone() == (1,)
        for test in spec.get('data_tests', []):
            if 'dbt_utils.expression_is_true' in test:
                expression = test['dbt_utils.expression_is_true']['arguments']['expression']
                expression = Environment(undefined=StrictUndefined).from_string(expression).render(
                    dbt_utils=dbt_utils_namespace())
                expression = sqlglot.transpile(expression, read='snowflake', write='sqlite')[0]
                assert not conn.execute(f'select 1 from {name} where not ({expression})').fetchall()
    for path in ['tests/singular/crime_category_consistency.sql', 'tests/singular/gold/gold_crime_roles.sql']:
        assert not conn.execute(sql_file(conn, path)).fetchall(), path
    assert not conn.execute('''select 1 from crimes c left join offense_categories o using (offense_category_id)
                              where c.offense_category_id is not null and o.offense_category_id is null''').fetchall()
    assert not conn.execute('''select 1 from fact_crimes c left join dim_offense_classification o
                              using (offense_classification_id)
                              where c.offense_classification_id is not null and o.offense_classification_id is null''').fetchall()


def integration_tests():
    with database() as conn:
        conn.executescript('''
            create table stg_crimes (
                report_number text, offense_id text, ingested_at text, offense_date text,
                offense_category text, offense_sub_category text, nibrs_offense_code text,
                precinct text, sector text, beat text, block_address text, latitude real, longitude real,
                neighborhood text, reporting_area text, census_block_2020 text,
                is_location_redacted boolean, has_missing_coordinates boolean, has_invalid_coordinates boolean,
                source_file text, batch_id text
            );
            create table reports (report_number text, report_id text);
            insert into reports values ('2026-000001', 'REPORT');
            create table nibrs (offense_code text, nibrs_key text);
            create table police_add (precinct text, sector text, beat text, police_area_id text);
            create table full_address (
                address_id text, block_address text, latitude real, longitude real,
                neighborhood text, reporting_area text, census_block_2020 text,
                is_location_redacted boolean, has_missing_coordinates boolean, has_invalid_coordinates boolean
            );
            insert into full_address (address_id) values ('UNKNOWN');
            create table dim_report (report_id text, report_date_time text);
            create table dim_date (full_date text, date_key integer);
        ''')
        pairs = [('PERSON', 'OTHER'), ('PROPERTY', 'OTHER'), ('PERSON', None),
                 (None, 'UNKNOWN'), (None, None), ('SOCIETY', 'DRUGS'), ('A|B', 'C'), ('A', 'B|C'),
                 ('PERSON', ''), ('', 'UNKNOWN')]

        def add(offense, day, pair):
            conn.execute('''insert into stg_crimes (report_number, offense_id, ingested_at,
                            offense_category, offense_sub_category) values ('2026-000001', ?, ?, ?, ?)''',
                         (offense, f'2026-01-{day:02d}', *pair))

        def rebuild(incremental=False):
            build(conn, 'offense_categories')
            build(conn, 'crimes', incremental)
            build(conn, 'dim_offense_classification')
            build(conn, 'fact_crimes')
            classification_tests(conn)
            columns = [row[1].lower() for row in conn.execute('pragma table_info(crimes)')]
            assert columns == ['crime_id', 'report_id', 'offense_id', 'offense_date', 'ingested_at',
                               'nibrs_key', 'offense_category_id', 'address_id', 'police_area_id'], columns

        for index, pair in enumerate(pairs):
            add(f'C{index}', 1, pair)
        add('C0', 1, pairs[0])  # La repetición no multiplica el catálogo ni el hecho.
        rebuild()
        assert conn.execute('select count(*) from offense_categories').fetchone() == (9,)
        assert conn.execute('select count(*) from crimes').fetchone() == (10,)
        assert conn.execute('select count(*) from crimes where offense_category_id is null').fetchone() == (1,)
        for offense, pair in [('C0', pairs[2]), ('C1', pairs[3]), ('C2', pairs[4])]:
            add(offense, 2, pair)
        rebuild(incremental=True)
        before = conn.execute('select * from crimes order by crime_id').fetchall()
        rebuild(incremental=True)
        assert conn.execute('select * from crimes order by crime_id').fetchall() == before
        rebuild()
        assert conn.execute('select * from crimes order by crime_id').fetchall() == before
        # La prueba de consistencia detecta una FK válida asignada a la pareja equivocada.
        conn.execute("update crimes set offense_category_id = (select offense_category_id from offense_categories where offense_category = 'SOCIETY') where offense_id = 'C0'")
        assert len(conn.execute(sql_file(conn, 'tests/singular/crime_category_consistency.sql')).fetchall()) == 1
        print('PASS: clasificación única, niveles parciales, FK nula, Gold, reemplazo incremental y reconstrucción')


if __name__ == '__main__':
    unit_tests()
    integration_tests()
