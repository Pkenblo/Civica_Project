"""Native dbt/Snowflake regression in a disposable, uniquely named schema.

Run with a Python that has dbt-snowflake, pyyaml and snowflake-connector-python:
  DBT_BIN=/path/to/dbt python tests/integration/arrest_merge_check.py
Uses the existing Snowflake connection (SNOWFLAKE_CONNECTION_NAME, default civica).
Never runs --full-refresh, and never writes to the project's RAW/STG/SILVER schemas.
"""

from __future__ import annotations

import datetime as dt
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
    project = Path(tempfile.mkdtemp(prefix='civica-arrest-merge-', dir='/tmp/opencode'))
    schema = 'OPENCODE_ARREST_MERGE_' + uuid.uuid4().hex[:12].upper()
    database = os.environ.get('DBT_TEST_DATABASE', 'DEV_BRONZE')
    assert re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', database)
    connection_name = os.environ.get('SNOWFLAKE_CONNECTION_NAME', 'civica')
    role = os.environ.get('DBT_TEST_ROLE', 'DEV_INGEST_ROLE')
    connection = tomllib.loads((Path.home() / '.snowflake/connections.toml').read_text())[connection_name]
    dbt = os.environ.get('DBT_BIN') or shutil.which('dbt')
    if not dbt:
        raise RuntimeError('Set DBT_BIN to the dbt executable.')
    profile = {k: connection[k] for k in ['account', 'user', 'warehouse']}
    profile.update(type='snowflake', role=role, authenticator='snowflake_jwt',
                   private_key_path=connection['private_key_file'], database=database, schema=schema, threads=1)
    (project / 'profiles.yml').write_text(yaml.safe_dump({'sandbox': {'target': 'test', 'outputs': {'test': profile}}}))
    config = yaml.safe_load((repo / 'dbt_project.yml').read_text())
    # The only coordinates in this sandbox are synthetic test coordinates.
    config.update(profile='sandbox', vars={'police_coordinates_epsg4326_confirmed': True})
    (project / 'dbt_project.yml').write_text(yaml.safe_dump(config))
    shutil.copy2(repo / 'packages.yml', project / 'packages.yml')
    shutil.copytree(repo / 'macros', project / 'macros')
    (project / 'macros/sandbox_schema.sql').write_text(
        '{% macro generate_schema_name(custom_schema_name, node) %}{{ target.schema }}{% endmacro %}')
    # Replace only the copied schema macro, avoiding duplicate macro definitions.
    for p in (project / 'macros').rglob('generate_schema_name.sql'):
        p.unlink()
    (project / 'models').mkdir()
    paths = {p.stem: p for p in (repo / 'models').rglob('*.sql')}
    selected = ['arrest', 'agents', 'subject', 'arrest_types', 'arrest_offenses', 'nibrs', 'cad_profiles',
                'arrest_conflicts', 'police_add', 'full_address', 'reports', 'stg_arrests']
    for name in selected:
        shutil.copy2(paths[name], project / 'models' / (name + '.sql'))
    shutil.copy2(repo / 'models/silver/arrests/_arrest_models.yml', project / 'models/arrest.yml')
    staging = yaml.safe_load((repo / 'models/staging/_stg_models.yml').read_text())
    staging['models'] = [m for m in staging['models'] if m['name'] == 'stg_arrests']
    (project / 'models/staging.yml').write_text(yaml.safe_dump(staging))
    silver = yaml.safe_load((repo / 'models/silver/_silver_models.yml').read_text())
    silver['models'] = [m for m in silver['models'] if m['name'] in selected]
    silver['unit_tests'] = [t for t in silver.get('unit_tests', []) if t['model'] in ['police_add', 'arrest_types', 'reports']]
    (project / 'models/catalogs.yml').write_text(yaml.safe_dump(silver))
    units = yaml.safe_load((repo / 'models/staging/_stg_unit_tests.yml').read_text())
    units['unit_tests'] = [t for t in units['unit_tests'] if t['model'] == 'stg_arrests']
    (project / 'models/staging_units.yml').write_text(yaml.safe_dump(units))
    source = yaml.safe_load((repo / 'models/bronze/brz_arrests.yml').read_text())
    source['sources'][0]['schema'] = schema
    source['sources'][0]['tables'][0]['identifier'] = 'RAW_ARRESTS_FIXTURE'
    (project / 'models/source.yml').write_text(yaml.safe_dump(source))
    (project / 'models/stg_crimes.sql').write_text("""{{ config(materialized='view') }}
select null::varchar offense_id, null::varchar report_number, null::timestamp_ntz report_date_time,
 null::varchar precinct, null::varchar sector, null::varchar beat, null::varchar block_address,
 null::number(18,5) latitude, null::number(18,5) longitude, null::varchar neighborhood,
 null::varchar reporting_area, null::varchar census_block_2020,
  false is_location_redacted, false has_missing_coordinates, false has_invalid_coordinates,
  catalog.column1::varchar as nibrs_offense_code, catalog.column2::varchar as nibrs_offense_code_description,
  null::varchar nibrs_group_a_b, null::varchar nibrs_crime_against_category
 from values ('13A', 'AGGRAVATED ASSAULT'), ('23A', 'POCKET-PICKING') as catalog
""")
    (project / 'models/postal_codes.sql').write_text("""{{ config(materialized='view') }}
select null::varchar cp, null::geography geography where false
""")
    shutil.copytree(repo / 'tests', project / 'tests', ignore=shutil.ignore_patterns('integration', '__pycache__'))
    env = dict(os.environ, DBT_SILVER=database, DBT_BRONZE=database,
               DBT_PROFILES_DIR=str(project), DBT_SEND_ANONYMOUS_USAGE_STATS='false')

    def run(*args):
        result = subprocess.run([dbt, '--no-use-colors', *args], cwd=project, env=env,
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        print(result.stdout, flush=True)
        if result.returncode:
            raise AssertionError(('dbt command failed', args, project))
        return json.loads((project / 'target/run_results.json').read_text()) if (project / 'target/run_results.json').exists() else None

    defaults = (repo / 'tests/unit/arrest_consolidation_preserves_values.sql').read_text().split('),\n\nfixture as (', 1)[0] + ')'
    date1, date2 = '2026-11-18 10:00:00 +00:00', '2026-11-19 10:00:00 +00:00'
    date_before = '2026-11-18 08:00:00 +00:00'
    date_between = '2026-11-18 15:00:00 +00:00'
    date_after = '2026-11-19 15:00:00 +00:00'
    public_location = dict(block_address='KEEP PUBLIC ADDRESS', latitude=47.12345, longitude=-122.12345)
    initial = [
        dict(id='ADDITIONAL', latitude=47.12345, officer_title='JOHN'),
        dict(id='NULLS', block_address='KEEP ADDRESS', latitude=47.12345, officer_title='JOHN', force_involved=True, cad_priority=0),
        dict(id='OLD', arrest_occurred_date_time='2011-01-01 00:00:00'),
        dict(id='COMPLETE', officer_title='ORIGINAL', block_address='A STREET', latitude=47.12345, longitude=-122.12345),
        dict(id='TIME_TIE', officer_title='OLD TITLE'),
        dict(id='OFFENSES', offense_type='CHARGE A', nibrs_description=' aggravated assault '),
        dict(id='OFFENSES', offense_type='CHARGE B', nibrs_description='POCKET-PICKING'),
        dict(id='REDACTED_INITIAL', **public_location),
        dict(id='REDACTED_NEWER', **public_location),
        dict(id='REDACTED_LATE', **public_location),
        dict(id='REDACTED_ONLY', block_address='REDACTED'),
        dict(id='IDENTITY', officer_id='A1', officer_title='OLD OFFICER', officer_age=40, officer_squad='NORTH',
             subject_id='P1', subject_age_range='18-24', subject_gender='MALE', subject_race='OLD RACE'),
    ]
    later = [
        dict(id='NEW_ID', officer_title='NEW OFFICER', cad_clearance='NEW INFORMATION'),
        dict(id='ADDITIONAL', block_address='MAIN STREET', longitude=-122.12345),
        dict(id='NULLS'),
        dict(id='OLD', arrest_occurred_date_time='2011-01-01 00:00:00', cad_clearance='NEW INFORMATION'),
        dict(id='COMPLETE', officer_title='CONTRADICTORY', cad_clearance='COMPLEMENT'),
        dict(id='TIME_TIE', officer_title='NEW TITLE'),
        dict(id='MULTI', officer_title='COMBINED OFFICER'),
        dict(id='MULTI', block_address='COMBINED ADDRESS', latitude=47.54321),
        dict(id='DECIMAL', raw_latitude='47.123456789', longitude=-122.12345),
        dict(id='DECIMAL', raw_latitude='47.123459999', longitude=-122.12345),
        dict(id='HASH_TIE', officer_title='ALPHA'),
        dict(id='HASH_TIE', officer_title='BETA'),
        dict(id='REDACTED_NEWER', block_address='REDACTED'),
        dict(id='REDACTED_LATE'),
        dict(id='IDENTITY', officer_id='A2', officer_title='NEW OFFICER', subject_id='P2', subject_age_range='35-44'),
    ]

    def literal(v):
        if v is None: return 'null'
        if isinstance(v, bool): return 'true' if v else 'false'
        if isinstance(v, (int, float)): return str(v)
        return "'" + v.replace("'", "''") + "'"

    mapping = {'AS_ON_SQUAD_DESC': 'officer_squad', 'INV_OFFICER_TITLE': 'officer_title', 'SK_PERSON': 'subject_id'}
    raw_columns = source['sources'][0]['tables'][0]['columns']

    def raw_rows(rows, ingestion, batch):
        versions = []
        for r in rows:
            data = dict(arrest_number=r['id'], ingested_at=ingestion,
                        arrest_occurred_date_time='2011-01-01 00:00:00',
                        arrest_reported_date_time='2011-01-01 01:00:00', report_number='2026-000001',
                        arrest_type='PHYSICAL ARREST', officer_id='O_' + r['id'])
            data.update({k: v for k, v in r.items() if k not in ['id', 'offense_type', 'nibrs_description', 'raw_latitude']})
            versions.append('select d.* replace (' + ', '.join(literal(v) + ' as ' + k for k, v in data.items()) + '), '
                            + literal(r.get('offense_type')) + '::varchar as offense_type, '
                            + literal(r.get('nibrs_description')) + '::varchar as nibrs_description, '
                            + literal(r.get('raw_latitude')) + '::varchar as raw_latitude from defaults d')
        expressions = []
        for col in raw_columns:
            name = col['name']
            if name == '_INGESTED_AT': expr = 'ingested_at::timestamp_ltz'
            elif name == '_BATCH_ID': expr = literal(batch)
            elif name == '_SOURCE_FILE': expr = literal('fixture_' + batch + '.csv')
            elif name == '_SOURCE_UPDATED_AT': expr = 'null::timestamp_tz'
            elif name in ['ARREST_OCCURRED_DATE_TIME', 'ARREST_REPORTED_DATE_TIME']:
                expr = "to_char(" + name.lower() + "::timestamp_ntz, 'MM/DD/YYYY HH12:MI:SS AM')"
            elif name == 'LATITUDE': expr = 'coalesce(raw_latitude, latitude::varchar)'
            else: expr = mapping.get(name, name.lower()) + '::varchar'
            expressions.append(expr + ' as ' + name)
        return defaults + ', staged as (' + ' union all '.join(versions) + ') select ' + ', '.join(expressions) + ' from staged'

    run('deps')
    created = False
    with snowflake.connector.connect(connection_name=connection_name, role=role, login_timeout=20, network_timeout=180) as c:
        with c.cursor() as q:
            table = f'{database}.{schema}.ARREST'
            raw = f'{database}.{schema}.RAW_ARRESTS_FIXTURE'

            def choices(id_):
                q.execute(f'select consolidation_choices from {table} where arrest_number=%s', (id_,))
                return json.loads(q.fetchone()[0])

            def snapshot():
                q.execute(f'select * from {table} order by arrest_number')
                return q.fetchall()

            def location(id_):
                q.execute(f'''select a.address_id, d.block_address, d.latitude::float, d.longitude::float, d.cp_status
                    from {table} a join {database}.{schema}.FULL_ADDRESS d on a.address_id = d.address_id
                    where a.arrest_number=%s''', (id_,))
                return q.fetchone()

            def identity():
                q.execute(f'''select g.officer_id, g.officer_title, a.agents_age_at_detention, g.squad_description,
                        s.sk_person, a.subgect_age_at_detention, s.subject_gender, s.subject_race
                    from {table} a
                    left join {database}.{schema}.AGENTS g on a.agent_key = g.agent_key
                    left join {database}.{schema}.SUBJECT s on a.subject_key = s.subject_key
                    where a.arrest_number = 'IDENTITY' ''')
                return q.fetchone()

            def cad_profile(id_):
                q.execute(f'''select a.cad_profile_id, p.cad_clearance, p.cad_initial_call_type, p.cad_priority
                    from {table} a left join {database}.{schema}.CAD_PROFILES p
                        on a.cad_profile_id = p.cad_profile_id
                    where a.arrest_number = %s''', (id_,))
                return q.fetchone()

            try:
                q.execute(f'create schema {database}.{schema}')
                created = True
                q.execute(f'create table {raw} as ' + raw_rows(initial, date1, '1001'))
                q.execute(f'insert into {raw} ' + raw_rows(
                    [dict(id='REDACTED_INITIAL', block_address='REDACTED')], date_between, 'initial_redacted'))
                q.execute(f'insert into {raw} ' + raw_rows([
                    dict(id='IDENTITY', officer_id='A2', officer_title='EARLIER TITLE', officer_squad='SOUTH',
                         subject_id='P2', subject_age_range='25-34', subject_gender='FEMALE'),
                ], date_before, 'older_identity'))
                run('parse', '--no-partial-parse')
                run('compile')
                run('run')
                expected_location = ('KEEP PUBLIC ADDRESS', 47.12345, -122.12345, 'no_match')
                initial_location = location('REDACTED_INITIAL')
                assert initial_location[1:] == expected_location, initial_location
                assert location('REDACTED_ONLY')[1:] == (None, None, None, 'redacted')
                assert identity() == ('A1', 'OLD OFFICER', 40, 'NORTH', 'P1', '18-24', 'MALE', 'OLD RACE')
                original_location = location('REDACTED_NEWER')
                q.execute(f'''update {table}
                    set consolidation_choices = object_insert(
                        consolidation_choices, 'cad_clearance', to_variant('KEEP DESTINATION'), true
                    ) where arrest_number = 'NULLS' ''')
                q.execute(f'insert into {raw} ' + raw_rows(later, date2, '2'))
                run('compile')
                run('run')
                expected_identity = ('A2', 'NEW OFFICER', None, 'SOUTH', 'P2', '35-44', 'FEMALE', None)
                assert identity() == expected_identity
                assert location('REDACTED_NEWER') == original_location == initial_location
                assert choices('NEW_ID')['officer_title'] == 'NEW OFFICER'
                a = choices('ADDITIONAL')
                assert a['officer_title'] == 'JOHN' and a['block_address'] == 'MAIN STREET' and a['latitude'] == 47.12345, a
                a = choices('NULLS')
                assert a['officer_title'] == 'JOHN' and a['block_address'] == 'KEEP ADDRESS' and a['latitude'] == 47.12345, a
                assert a['cad_clearance'] == 'KEEP DESTINATION', a
                assert cad_profile('NULLS')[1:] == ('KEEP DESTINATION', None, 0)
                q.execute(f"select force_involved from {table} where arrest_number='NULLS'")
                assert q.fetchone() == (True,)
                a = choices('MULTI')
                assert a['officer_title'] == 'COMBINED OFFICER' and a['block_address'] == 'COMBINED ADDRESS', a
                q.execute(f"select source_version_count,consolidation_conflicts:latitude from {table} where arrest_number='DECIMAL'")
                assert q.fetchone() == (1, None)
                assert choices('DECIMAL')['latitude'] == 47.12346
                q.execute(f"select last_ingested_at from {table} where arrest_number='OLD'")
                assert q.fetchone() == (dt.datetime.fromisoformat(date2),)
                repeated_profile = cad_profile('OLD')
                assert repeated_profile[1:] == ('NEW INFORMATION', None, None)
                assert cad_profile('NEW_ID') == repeated_profile
                assert cad_profile('TIME_TIE') == (None, None, None, None)
                original_cad_profile = cad_profile('COMPLETE')
                a = choices('COMPLETE')
                assert (a['block_address'], a['cad_clearance'], a['officer_title']) == (
                    'A STREET', 'COMPLEMENT', 'CONTRADICTORY'), a
                assert choices('TIME_TIE')['officer_title'] == 'NEW TITLE'
                q.execute(f"select array_size(observed_values),selected_value::varchar from {database}.{schema}.ARREST_CONFLICTS where arrest_number='COMPLETE' and field_name='officer_title'")
                assert q.fetchone() == (2, 'CONTRADICTORY')
                # El fixture declara las columnas en el orden esperado del desempate.
                columns = re.findall(r'\bas (\w+)', defaults)[2:]
                parts = [f"coalesce(to_variant({col}),parse_json('null'))" for col in columns]
                q.execute('select officer_title from ' + database + '.' + schema + '.STG_ARRESTS where arrest_number=\'HASH_TIE\' order by sha2(to_json(array_construct(' + ', '.join(parts) + ')),256) desc limit 1')
                expected_title = q.fetchone()[0]
                assert choices('HASH_TIE')['officer_title'] == expected_title
                q.execute(f'select count(*),count(distinct arrest_number) from {table}')
                assert q.fetchone() == (15, 15)
                q.execute(f'''select detail.offense_type, catalog.offense_code
                    from {database}.{schema}.ARREST_OFFENSES as detail
                    left join {database}.{schema}.NIBRS as catalog on detail.nibrs_key = catalog.nibrs_key
                    where detail.arrest_number = 'OFFENSES'
                    order by detail.offense_type''')
                assert q.fetchall() == [('CHARGE A', '13A'), ('CHARGE B', '23A')]
                q.execute(f'insert into {raw} ' + raw_rows([
                    dict(id='REDACTED_LATE', block_address='REDACTED'),
                    dict(id='COMPLETE', officer_title='LATE OLD TITLE', cad_initial_call_type='LATE COMPLEMENT'),
                ], date_between, 'late_version'))
                q.execute(f'insert into {raw} ' + raw_rows([
                    dict(id='IDENTITY', officer_id=None, officer_title='UNATTRIBUTED TITLE', officer_age=99,
                         subject_id=None, subject_age_range='UNATTRIBUTED AGE', subject_race='UNATTRIBUTED RACE'),
                ], date_after, 'missing_identity'))
                run('run')
                assert identity() == expected_identity
                a = choices('COMPLETE')
                assert (a['officer_title'], a['cad_initial_call_type']) == ('CONTRADICTORY', 'LATE COMPLEMENT'), a
                updated_cad_profile = cad_profile('COMPLETE')
                assert updated_cad_profile[0] != original_cad_profile[0]
                assert updated_cad_profile[1:] == ('COMPLEMENT', 'LATE COMPLEMENT', None)
                assert location('REDACTED_LATE') == initial_location
                q.execute(f"select source_version_count, last_ingested_at from {table} where arrest_number='REDACTED_LATE'")
                version_count, last_ingested_at = q.fetchone()
                assert version_count == 3
                assert last_ingested_at == dt.datetime.fromisoformat(date2)
                before = snapshot()
                results = run('run', '--select', 'arrest')
                assert snapshot() == before
                arrest_result = next(r for r in results['results'] if r['unique_id'].endswith('.arrest'))
                assert arrest_result['adapter_response'].get('rows_affected') == 0, arrest_result['adapter_response']
                print('PASS integration: recency, identity, late versions, REDACTED, charges and idempotence.', flush=True)
                run('test')
                print('PASS native dbt parse, compile, run and test. Project:', project, flush=True)
            finally:
                if created:
                    assert schema.startswith('OPENCODE_ARREST_MERGE_')
                    q.execute(f'drop schema {database}.{schema} cascade')
                    print('Removed only the uniquely named schema created by this test.', flush=True)


if __name__ == '__main__':
    main()
