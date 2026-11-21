"""Regresión nativa de Silver con datos sintéticos y un esquema DEV de un solo uso.

DBT_BIN=/ruta/a/dbt python tests/integration/arrest_delete_insert_check.py
Usa la conexión JWT externa SNOWFLAKE_CONNECTION_NAME (por defecto civica).
"""

import json
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
    if not re.fullmatch(r'DEV_[A-Z0-9_]+', database):
        raise ValueError('DBT_TEST_DATABASE debe ser una base DEV')
    schema = 'SILVER_REGRESSION_' + uuid.uuid4().hex.upper()
    namespace = f'{database}.{schema}'
    name = os.environ.get('SNOWFLAKE_CONNECTION_NAME', 'civica')
    role = os.environ.get('DBT_TEST_ROLE', 'DEV_INGEST_ROLE')
    settings = tomllib.loads((Path.home() / '.snowflake/connections.toml').read_text())[name]

    with tempfile.TemporaryDirectory(prefix='silver-regression-') as work:
        project = Path(work)
        for folder in ('models', 'macros', 'tests/singular'):
            # Este fixture solo construye Bronze/staging/Silver, no Gold.
            shutil.copytree(repo / folder, project / folder, ignore=shutil.ignore_patterns('gold'))
        for file in ('dbt_project.yml', 'packages.yml', 'package-lock.yml'):
            shutil.copy2(repo / file, project)
        # Solo la copia del proyecto: aislar RAW, STG y SILVER del despliegue real.
        (project / 'macros/utils/generate_schema_name.sql').write_text(
            '{% macro generate_schema_name(custom_schema_name, node) %}{{ target.schema }}{% endmacro %}')
        ddl = []
        for path in (project / 'models/bronze').glob('*.yml'):
            doc = yaml.safe_load(path.read_text())
            source, = doc['sources']
            table, = source['tables']
            source['schema'] = schema
            table['identifier'] = 'FIXTURE_' + table['identifier']
            columns = ', '.join(f"{c['name']} {c['data_type']}" for c in table['columns'])
            ddl.append(f"create table {namespace}.{table['identifier']} ({columns})")
            path.write_text(yaml.safe_dump(doc))
        profile = {k: settings[k] for k in ('account', 'user', 'warehouse')}
        profile.update(type='snowflake', role=role, authenticator='snowflake_jwt', threads=2,
                       private_key_path=settings['private_key_file'], database=database, schema=schema)
        (project / 'profiles.yml').write_text(yaml.safe_dump({'default': {'target': 'dev', 'outputs': {'dev': profile}}}))
        env = dict(os.environ, DBT_BRONZE=database, DBT_SILVER=database, DBT_PROFILES_DIR=work,
                   DBT_SEND_ANONYMOUS_USAGE_STATS='false')
        variables = json.dumps(dict(zipcode_boundary_version='fixture', zipcode_expected_feature_count=1))

        def run(*args):
            subprocess.run([os.environ.get('DBT_BIN', 'dbt'), *args], cwd=project, env=env, check=True)

        def build(*args):
            run('build', '--vars', variables, *args)

        run('deps')
        with snowflake.connector.connect(connection_name=name, role=role, login_timeout=20) as conn, conn.cursor() as q:
            def rows(sql):
                return q.execute(sql).fetchall()

            def add(table, day, **fields):
                fields['_INGESTED_AT'] = f'2026-01-{day:02d} 10:00:00 +00:00'
                q.execute(f"insert into FIXTURE_{table} ({', '.join(fields)}) values "
                          f"({', '.join(['%s'] * len(fields))})", tuple(fields.values()))

            q.execute(f'create schema {namespace}')
            try:
                q.execute(f'use schema {namespace}')
                for statement in ddl:
                    q.execute(statement)
                feature = {'type': 'Feature', 'properties': {'OBJECTID': 1, 'ZIPCODE': '00501'},
                           'geometry': {'type': 'Polygon', 'coordinates': [[[0, 0], [2, 0], [2, 2], [0, 2], [0, 0]]]}}
                q.execute("insert into FIXTURE_ZIPCODE_AREAS (feature, boundary_version) select parse_json(%s), 'fixture'",
                          (json.dumps(feature),))
                dt = '01/01/2026 10:00:00 AM'
                arrest = dict(ARREST_NUMBER='A1', REPORT_NUMBER='20260000000001', ARREST_TYPE='OLD',
                              ARREST_OCCURRED_DATE_TIME=dt, ARREST_REPORTED_DATE_TIME=dt, OFFICER_ID='O1',
                              SK_PERSON='P1', LATITUDE='1', LONGITUDE='1', OFFICER_AGE='40')
                crime = dict(REPORT_NUMBER='2026-000001', OFFENSE_ID='C1', REPORT_DATE_TIME=dt,
                             OFFENSE_DATE=dt, OFFENSE_CATEGORY='CAT', OFFENSE_SUB_CATEGORY='SUB')
                pet = dict(LICENSE_NUMBER='L1', LICENSE_ISSUE_DATE='January 01 2026', SPECIES='DOG', PRIMARY_BREED='B')
                for charge in ('CHARGE A', 'CHARGE B'):
                    add('ARRESTS', 2, **arrest, OFFENSE_TYPE=charge)
                for label in ('TYPE A', 'TYPE B'):
                    add('CRIMES', 2, **crime, SHOOTING_TYPE_GROUP=label)
                add('PET_LICENSES', 2, **pet, ANIMAL_S_NAME='DOG A', ZIP_CODE='00501')
                build()
                assert rows('select d.cp from arrest a join full_address d using (address_id)') == [('00501',)]
                assert rows('select distinct report_id from arrest minus select report_id from crimes') == []
                assert rows('select animal_name from licenses') == [('DOG A',)]
                assert rows('select count(*) from crime_shooting_types') == [(2,)]
                # Una versión con ingesta más reciente sustituye la anterior, incluso con NULL.
                add('ARRESTS', 3, **(arrest | dict(ARREST_TYPE='NEW', OFFICER_ID=None, OFFICER_AGE=None,
                                                   BLOCK_ADDRESS='REDACTED')), OFFENSE_TYPE='CHARGE C')
                add('CRIMES', 3, **(crime | dict(OFFENSE_SUB_CATEGORY=None)), SHOOTING_TYPE_GROUP='TYPE C')
                add('PET_LICENSES', 3, **pet, ANIMAL_S_NAME=None)
                build()
                # Una clave nueva en un lote anterior o con la misma ingesta no cruza el corte.
                for day in (1, 3):
                    add('ARRESTS', day, **(arrest | dict(ARREST_NUMBER='A2')))
                    add('CRIMES', day, **(crime | dict(OFFENSE_ID='C2')))
                    add('PET_LICENSES', day, **(pet | dict(LICENSE_NUMBER='L2')))
                add('PET_LICENSES', 1, **pet, ANIMAL_S_NAME='OBSOLETE')
                add('ARRESTS', 4, **(arrest | dict(ARREST_NUMBER='A3')))
                add('CRIMES', 4, **(crime | dict(OFFENSE_ID='C3')))
                # Las dos versiones cruzan el corte: el desempate sigue eligiendo una.
                add('PET_LICENSES', 4, **(pet | dict(LICENSE_NUMBER='L3')), ANIMAL_S_NAME='OTHER', _SOURCE_FILE='a.csv')
                add('PET_LICENSES', 4, **(pet | dict(LICENSE_NUMBER='L3')), ANIMAL_S_NAME='TIE', _SOURCE_FILE='z.csv')
                for _ in range(2):
                    # Estas pruebas de cobertura detectan justamente las omisiones provocadas aquí.
                    build('--exclude', 'arrest_source_ids_complete', 'crime_source_ids_complete',
                          'license_source_ids_complete')
                    assert rows('select arrest_number from arrest order by 1') == [('A1',), ('A3',)]
                    assert rows("select agent_key, officer_age, d.cp_status, t.description from arrest a "
                                "join full_address d using (address_id) join arrest_types t using (arrest_type_id) "
                                "where arrest_number='A1'") == [(None, None, 'redacted', 'NEW')]
                    assert rows('select count(*) from arrest_offenses') == [(3,)]
                    assert rows('select offense_id, offense_subcategory_id is null from crimes order by 1') == [('C1', True), ('C3', False)]
                    assert rows('select count(*) from crime_shooting_types') == [(3,)]
                    assert rows('select license_number, animal_name, cp from licenses order by 1') == [('L1', None, None), ('L3', 'TIE', None)]
                build('--full-refresh')
                assert rows("select arrest_number from arrest where arrest_number = 'A2'") == [('A2',)]
                assert rows("select offense_id from crimes where offense_id = 'C2'") == [('C2',)]
                assert rows("select license_number from licenses where license_number = 'L2'") == [('L2',)]
                print('PASS: corte global, NULL, empates del lote nuevo, catálogos, puentes, repetición y full refresh.')
            finally:
                q.execute(f'drop schema {namespace} cascade')


if __name__ == '__main__':
    main()
