"""Run the arrest delete+insert regression in its own Snowflake schema (never DEV Silver).

DBT_BIN=/path/to/dbt python tests/integration/arrest_delete_insert_check.py
Uses SNOWFLAKE_CONNECTION_NAME (default civica) with JWT configured outside the repo.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib
import uuid

import snowflake.connector
import yaml


def main():
    os.umask(0o077)
    repo = Path(__file__).resolve().parents[2]
    database = os.environ.get('DBT_TEST_DATABASE', 'DEV_BRONZE')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', database):
        raise ValueError('Invalid DBT_TEST_DATABASE')
    schema = 'ARREST_DELETE_INSERT_' + uuid.uuid4().hex[:12].upper()
    namespace = f'{database}.{schema}'
    connection_name = os.environ.get('SNOWFLAKE_CONNECTION_NAME', 'civica')
    role = os.environ.get('DBT_TEST_ROLE', 'DEV_INGEST_ROLE')
    settings = tomllib.loads((Path.home() / '.snowflake/connections.toml').read_text())[connection_name]
    raw = f'{namespace}.RAW_ARRESTS_FIXTURE'
    source = yaml.safe_load((repo / 'models/bronze/brz_arrests.yml').read_text())
    source['sources'][0]['schema'] = schema
    source['sources'][0]['tables'][0]['identifier'] = 'RAW_ARRESTS_FIXTURE'
    columns = source['sources'][0]['tables'][0]['columns']

    with tempfile.TemporaryDirectory(prefix='civica-arrest-delete-insert-') as work:
        project = Path(work)
        (project / 'models').mkdir()
        (project / 'macros').mkdir()
        (project / 'tests').mkdir()
        for name in ('arrest', 'stg_arrests', 'agents', 'subject', 'arrest_offenses',
                     'arrest_types', 'cad_profiles', 'police_add', 'full_address', 'reports'):
            path, = (repo / 'models').rglob(f'{name}.sql')
            shutil.copy2(path, project / 'models')
        for path in (repo / 'tests/singular').glob('arrest_*.sql'):
            shutil.copy2(path, project / 'tests')
        shutil.copy2(repo / 'models/silver/arrests/_arrest_models.yml', project / 'models')
        configs = yaml.safe_load((repo / 'models/silver/_silver_models.yml').read_text())
        configs = [model for model in configs['models']
                   if model['name'] in ('arrest_types', 'police_add', 'reports')]
        (project / 'models/catalogs.yml').write_text(yaml.safe_dump({'version': 2, 'models': configs}))
        # Other domains are synthetic. The CRS override below applies only to these fixtures.
        (project / 'models/stg_crimes.sql').write_text(f'select * from {namespace}.CRIMES_FIXTURE')
        (project / 'models/nibrs.sql').write_text(f'select * from {namespace}.NIBRS_FIXTURE')
        (project / 'models/postal_codes.sql').write_text(
            'select null::varchar as cp, to_geography(null::varchar) as geography where false')
        for name in ('nullif_any', 'changed_catalog_rows'):
            path, = (repo / 'macros').rglob(f'{name}.sql')
            shutil.copy2(path, project / 'macros')
        shutil.copy2(repo / 'packages.yml', project)
        (project / 'models/source.yml').write_text(yaml.safe_dump(source))
        (project / 'macros/sandbox_schema.sql').write_text(
            '{% macro generate_schema_name(custom_schema_name, node) %}{{ target.schema }}{% endmacro %}')
        (project / 'dbt_project.yml').write_text('name: arrest_regression\nversion: "1.0.0"\nconfig-version: 2\nprofile: sandbox\n')
        profile = {k: settings[k] for k in ('account', 'user', 'warehouse')}
        profile.update(type='snowflake', role=role, authenticator='snowflake_jwt',
                       private_key_path=settings['private_key_file'], database=database, schema=schema, threads=1)
        (project / 'profiles.yml').write_text(yaml.safe_dump({'sandbox': {'target': 'test', 'outputs': {'test': profile}}}))
        env = dict(os.environ, DBT_BRONZE=database, DBT_SILVER=database,
                   DBT_PROFILES_DIR=work, DBT_SEND_ANONYMOUS_USAGE_STATS='false')

        def run(*args):
            subprocess.run([os.environ.get('DBT_BIN', 'dbt'), *args], cwd=project, env=env, check=True)

        run('deps')
        early, latest = '2026-11-18 10:00:00 +00:00', '2026-11-19 10:00:00 +00:00'
        build_args = ('--vars', '{police_coordinates_epsg4326_confirmed: true}')
        with snowflake.connector.connect(connection_name=connection_name, role=role, login_timeout=20) as conn:
            with conn.cursor() as q:
                def insert(number, ingested_at, **attributes):
                    names = ', '.join(('ARREST_NUMBER', '_INGESTED_AT', *attributes))
                    tail = ', %s' * len(attributes)
                    q.execute(f'insert into {raw} ({names}) select %s, to_timestamp_ltz(%s){tail}',
                              (number, ingested_at, *attributes.values()))

                def rows(sql):
                    return q.execute(sql).fetchall()

                def arrest_row():
                    row, = rows(f'''select a.last_ingested_at, a.block_address, a.latitude,
                        a.cad_priority, a.force_involved, a.sector, address.cp_status,
                        a.agent_key, a.subject_key, a.agents_age_at_detention, a.subgect_age_at_detention
                        from {namespace}.ARREST a
                        left join {namespace}.FULL_ADDRESS address on a.address_id = address.address_id
                        where a.arrest_number = 'A1' ''')
                    return row

                q.execute(f'create schema {namespace}')
                try:
                    definition = ', '.join(f"{col['name']} {col['data_type']}" for col in columns)
                    q.execute(f'create table {raw} ({definition})')
                    q.execute(f'''create table {namespace}.CRIMES_FIXTURE (
                        report_number varchar, report_date_time timestamp_ntz, precinct varchar, sector varchar,
                        beat varchar, offense_id varchar, block_address varchar, latitude number(18,5),
                        longitude number(18,5), neighborhood varchar, reporting_area varchar,
                        census_block_2020 varchar, is_location_redacted boolean, has_missing_coordinates boolean,
                        has_invalid_coordinates boolean)''')
                    q.execute(f'create table {namespace}.NIBRS_FIXTURE (offense_description varchar, nibrs_key varchar)')
                    insert('A1', early, BLOCK_ADDRESS='PUBLIC ADDRESS', LATITUDE='47.123456', LONGITUDE='-122.12345',
                           REPORT_NUMBER='20260000000001', ARREST_TYPE='CITATION', PRECINCT='NORTH', SECTOR='J',
                           OFFICER_ID='O1', INV_OFFICER_TITLE='OLD TITLE', AS_ON_SQUAD_DESC='WEST', OFFICER_AGE='40',
                           SK_PERSON='S1', SUBJECT_GENDER='FEMALE', SUBJECT_RACE='OLD RACE', SUBJECT_AGE_RANGE='18-24',
                           OFFENSE_TYPE='CHARGE A', NIBRS_DESCRIPTION='DESCRIPTION A')
                    run('run', *build_args)
                    original = arrest_row()
                    assert original[1] == 'PUBLIC ADDRESS' and original[6] == 'no_match', original

                    # Mismo ID: sustituye la fila completa y mantiene las referencias de persona.
                    insert('A1', latest, BLOCK_ADDRESS='REDACTED', LATITUDE='0', CAD_PRIORITY='0', FORCE_INVOLVED='false',
                           OFFICER_ID='O1', INV_OFFICER_TITLE='NEW TITLE', SK_PERSON='S1', SUBJECT_GENDER='MALE',
                           OFFENSE_TYPE='CHARGE B', _SOURCE_FILE='01.csv')
                    insert('A2', early, _SOURCE_FILE='01.csv')
                    # Cambios bajo claves ya existentes en catálogos compartidos.
                    q.execute(f'''insert into {namespace}.CRIMES_FIXTURE (report_number, report_date_time)
                                  values ('2026-000001', '2026-01-19 12:00:00')''')
                    q.execute(f"insert into {namespace}.NIBRS_FIXTURE values ('DESCRIPTION A', 'K1')")
                    run('run', *build_args)
                    current = arrest_row()
                    assert current[0] > original[0]
                    assert current[1:7] == (None, None, 0, False, None, 'redacted'), current
                    assert current[7:9] == original[7:9] and current[9:] == (None, None), current
                    assert rows(f'select officer_id, officer_title, squad_description from {namespace}.AGENTS') == [
                        ('O1', 'NEW TITLE', None)]
                    assert rows(f'select sk_person, subject_gender, subject_race from {namespace}.SUBJECT') == [
                        ('S1', 'MALE', None)]
                    assert rows(f'select report_number, report_date_time is not null from {namespace}.REPORTS') == [
                        ('2026-000001', True)]
                    assert rows(f'select offense_type, nibrs_key from {namespace}.ARREST_OFFENSES order by 1') == [
                        ('CHARGE A', 'K1'), ('CHARGE B', None)]

                    # Una ingesta más antigua no pisa la última; un fichero distinto puede desempatar.
                    insert('A1', early, SECTOR='OLD SECTOR', OFFICER_ID='O1', SK_PERSON='S1')
                    insert('A2', early, CAD_INITIAL_CALL_TYPE='CALL TYPE', _SOURCE_FILE='02.csv')
                    run('run', *build_args)
                    assert arrest_row() == current
                    query = (f'select arrest_number, cad_initial_call_type, agent_key is null, subject_key is null '
                             f'from {namespace}.ARREST order by arrest_number')
                    actual = rows(query)
                    assert actual == [('A1', None, False, False), ('A2', 'CALL TYPE', True, True)], actual
                    run('run', *build_args)
                    assert rows(query) == actual and arrest_row() == current
                    run('test', '--select', 'test_type:data')
                    print('PASS: row replacement, stable person keys, catalog updates and repeatability.')
                finally:
                    q.execute(f'drop schema {namespace} cascade')


if __name__ == '__main__':
    main()
