"""Regresión SQLite del contexto del agente en cada detención, sin Snowflake.

python tests/integration/arrest_officer_context_local_check.py
Requiere Jinja2, PyYAML y sqlglot. Ejecuta el SQL real traducido a SQLite;
no valida la serialización exacta de Snowflake.
"""

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
    'agents': 'models/silver/persons/agents.sql',
    'arrest': 'models/silver/arrests/arrest.sql',
    'dim_agent': 'models/gold/dimensions/dim_agent.sql',
    'fact_arrests': 'models/gold/facts/fact_arrests.sql',
}


def build(conn, name, incremental=False):
    template = (ROOT / 'macros/utils/address_id.sql').read_text() + (ROOT / MODELS[name]).read_text()
    rendered = Environment(undefined=StrictUndefined).from_string(template).render(
        config=lambda **kwargs: '', ref=lambda model: model, is_incremental=lambda: incremental,
        after_max_ingested_at=lambda column: f'{column} > (select max(ingested_at) from {name})',
        dbt_utils=dbt_utils_namespace(),
    )
    expression = sqlglot.parse_one(rendered, read='snowflake')
    if name == 'arrest':
        schema = {table: {col[1]: col[2] or 'TEXT' for col in conn.execute(f'pragma table_info({table})')}
                  for table, in conn.execute("select name from sqlite_master where type = 'table'").fetchall()}
        expression = qualify(expression, dialect='snowflake', schema=schema)
    conn.execute(f'create table next_rows as {expression.sql(dialect="sqlite")}')
    if incremental:
        conn.execute(f'delete from {name} where arrest_number in (select arrest_number from next_rows)')
        conn.execute(f'insert into {name} select * from next_rows')
        conn.execute('drop table next_rows')
    else:
        conn.execute(f'drop table if exists {name}')
        conn.execute(f'alter table next_rows rename to {name}')


def main():
    with sqlite3.connect(':memory:') as conn:
        conn.create_function('MD5', 1, lambda value: hashlib.md5(value.encode()).hexdigest() if value is not None else None)
        conn.create_function('ARRAY', -1, lambda *values: json.dumps(values, separators=(',', ':')))
        conn.create_function('JSON_FORMAT', 1, lambda value: value)
        conn.create_function('EQUAL_NULL', 2, lambda left, right: left == right)
        conn.executescript('''
            create table stg_arrests (
                arrest_number text, ingested_at text, arrest_occurred_date_time text,
                arrest_reported_date_time text, report_number text, arrest_type text,
                officer_id text, officer_gender text, officer_race text, officer_age integer,
                officer_squad text, officer_title text, subject_id text, subject_age_range text,
                cad_clearance text, cad_initial_call_type text, cad_priority integer,
                precinct text, sector text, beat text, block_address text, latitude real, longitude real,
                neighborhood text, reporting_area text, census_block_2020 text,
                has_invalid_coordinates boolean, is_location_redacted boolean,
                crisis_involved boolean, complaint_involved boolean, force_involved boolean,
                terry_stop boolean, demonstration boolean, source_file text, batch_id text
            );
            create table reports (report_number text, report_id text);
            create table arrest_types (description text, arrest_type_id text);
            create table subject (sk_person text, subject_key text);
            create table cad_profiles (cad_clearance text, cad_initial_call_type text, cad_priority integer, cad_profile_id text);
            create table police_add (precinct text, sector text, beat text, police_area_id text);
            create table full_address (address_id text);
            insert into full_address values ('UNKNOWN');
            create table dim_date (full_date text, date_key integer);
        ''')

        def add(number, day, squad, title, officer='O1', age=None):
            conn.execute('''insert into stg_arrests
                            (arrest_number, ingested_at, officer_id, officer_squad, officer_title, officer_age)
                            values (?, ?, ?, ?, ?, ?)''', (number, f'2026-01-{day:02d}', officer, squad, title, age))

        def rebuild(incremental=False):
            for name in MODELS:
                build(conn, name, incremental and name in ('arrest', 'fact_arrests'))
            for name in ('agents', 'dim_agent'):
                columns = [row[1].lower() for row in conn.execute(f'pragma table_info({name})')]
                assert columns == ['agent_key', 'officer_id', 'officer_gender', 'officer_race'], columns
            # La igualdad declarada en Gold incluye ambos campos y conserva sus nulos.
            spec = next(model for model in yaml.safe_load((ROOT / 'models/gold/facts/_facts.yml').read_text())['models']
                        if model['name'] == 'fact_arrests')
            equality = next(test['dbt_utils.equality']['arguments'] for test in spec['data_tests'] if 'dbt_utils.equality' in test)
            columns = equality['compare_columns']
            assert {'officer_squad_at_arrest', 'officer_title_at_arrest'} <= set(columns)
            projection = ', '.join(columns)
            assert conn.execute(f'select {projection} from fact_arrests order by arrest_number').fetchall() == conn.execute(
                f'select {projection} from arrest order by arrest_number').fetchall()

        def context():
            return conn.execute('''select arrest_number, officer_squad_at_arrest, officer_title_at_arrest
                                   from arrest order by arrest_number''').fetchall()

        add('A1', 1, 'PATROL', 'OFFICER')
        add('A2', 2, 'DETECTIVES', 'SERGEANT')
        add('A3', 2, 'TRAFFIC', 'OFFICER', officer=None)
        add('A4', 2, None, None)
        # Empate en toda la fila salvo los nuevos atributos: desempate estable.
        add('A5', 2, 'A', 'OFFICER')
        add('A5', 2, 'Z', 'OFFICER')
        add('A6', 2, 'PATROL', 'A')
        add('A6', 2, 'PATROL', 'Z')
        # El desempate usa el tipo numérico original, no el orden del texto serializado.
        add('A7', 2, 'PATROL', 'OFFICER', age=9)
        add('A7', 2, 'PATROL', 'OFFICER', age=10)
        add('A8', 2, 'PATROL', 'OFFICER', age=None)
        add('A8', 2, 'PATROL', 'OFFICER', age=5)
        rebuild()
        assert context() == [('A1', 'PATROL', 'OFFICER'), ('A2', 'DETECTIVES', 'SERGEANT'),
                             ('A3', 'TRAFFIC', 'OFFICER'), ('A4', None, None),
                             ('A5', 'Z', 'OFFICER'), ('A6', 'PATROL', 'Z'),
                             ('A7', 'PATROL', 'OFFICER'), ('A8', 'PATROL', 'OFFICER')]
        assert conn.execute("select officer_age from arrest where arrest_number in ('A7', 'A8') order by arrest_number").fetchall() == [(10,), (5,)]
        assert conn.execute("select agent_key from arrest where arrest_number = 'A3'").fetchone() == (None,)
        add('A1', 3, None, None)
        add('A2', 3, 'TRAFFIC', None)
        rebuild(incremental=True)
        assert context()[:2] == [('A1', None, None), ('A2', 'TRAFFIC', None)]
        before = conn.execute('select * from arrest order by arrest_number').fetchall()
        rebuild(incremental=True)
        assert conn.execute('select * from arrest order by arrest_number').fetchall() == before
        rebuild()
        assert conn.execute('select * from arrest order by arrest_number').fetchall() == before
        print('PASS: contexto por detención, agente ausente, nulos, desempates, Gold, incremental y full refresh')


if __name__ == '__main__':
    main()
