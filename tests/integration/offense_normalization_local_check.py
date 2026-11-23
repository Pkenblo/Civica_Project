"""Ejecuta el SQL de normalización en DuckDB, sin escribir en Snowflake.

Dependencias de prueba: duckdb, sqlglot, jinja2.
python tests/integration/offense_normalization_local_check.py --snapshot-dir DIR
python tests/integration/offense_normalization_local_check.py --offense-types-csv ARCHIVO --output-dir DIR

El directorio opcional contiene las consultas públicas guardadas como JSON:
arrest_observations, offense_frequencies, arrest_nibrs_frequencies y crime_nibrs.
Esta regresión transpila el SQL Snowflake; no sustituye dbt test en Snowflake.
"""

import argparse
from collections import Counter
import csv
import hashlib
import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen

import duckdb
from jinja2 import Environment, StrictUndefined
import sqlglot
from sqlglot import exp

from local_dbt_utils import dbt_utils_namespace


ROOT = Path(__file__).resolve().parents[2]
MODELS = {
    'offense_types': 'models/silver/arrests/offense_types.sql',
    'arrest_offenses': 'models/silver/arrests/arrest_offenses.sql',
    'dim_offense_types': 'models/gold/dimensions/dim_offense_types.sql',
    'bridge_arrest_offenses': 'models/gold/bridges/bridge_arrest_offenses.sql',
}
CATALOG_COLUMNS = [
    'offense_type_id', 'offense_type', 'offense_type_original_values',
    'legal_source', 'legal_code', 'secondary_legal_source', 'secondary_legal_code',
    'external_code', 'offense_description', 'offense_category', 'parse_status',
]


def render(path):
    template = Environment(undefined=StrictUndefined).from_string((ROOT / path).read_text())
    return template.render(config=lambda **kwargs: '', ref=lambda name: name,
                           dbt_utils=dbt_utils_namespace(), is_incremental=lambda: False)


def translate(sql):
    return sqlglot.transpile(sql, read='snowflake', write='duckdb')[0]


def column_type(name):
    if name == 'ingested_at':
        return 'timestamp'
    if name == 'offense_type_original_values':
        return 'varchar[]'
    return 'varchar'


def fixture(conn, name, rows):
    columns = list(dict.fromkeys(key for row in rows for key in row))
    ddl = ', '.join(f'"{col}" {column_type(col)}' for col in columns)
    conn.execute(f'create or replace table "{name}" ({ddl})')
    conn.executemany(f'insert into "{name}" values ({", ".join("?" for _ in columns)})',
                     [[row.get(col) for col in columns] for row in rows])
    return columns


def assert_catalog_schema(conn, name):
    columns = [column[0] for column in conn.execute(f'select * from {name} limit 0').description]
    expected = CATALOG_COLUMNS + ['ingested_at']
    assert columns == expected, (name, columns)


def download_snapshot(directory):
    directory.mkdir(parents=True, exist_ok=True)
    queries = {
        'arrest_observations': ('9bjs-7a7w', 'arrest_number,offense_type,nibrs_description'),
        'offense_frequencies': ('9bjs-7a7w', 'offense_type'),
        'arrest_nibrs_frequencies': ('9bjs-7a7w', 'nibrs_description'),
        'crime_nibrs': ('tazs-3rd5', 'nibrs_offense_code,nibrs_offense_code_description'),
    }
    for name, (dataset, fields) in queries.items():
        result = []
        offset = 0
        while True:
            params = {'$select': fields + ',count(*) as frequency', '$group': fields,
                      '$order': fields, '$limit': 50000, '$offset': offset}
            with urlopen('https://data.seattle.gov/resource/' + dataset + '.json?' + urlencode(params), timeout=120) as response:
                page = json.load(response)
            result.extend(page)
            if len(page) < 50000:
                break
            offset += len(page)
        (directory / (name + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')


def export_csv(conn, path, query):
    cursor = conn.execute(query)
    with path.open('w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow([column[0] for column in cursor.description])
        writer.writerows(cursor.fetchall())


def snapshot_tests(directory):
    # Datos agregados: frequency conserva el número de filas originales, no versiones de ingesta.
    # La fecha fija es sintética y solo permite ejecutar la carga inicial del incremental.
    directory = directory.resolve()
    with duckdb.connect() as conn:
        conn.execute("create table observations as select * from read_json_auto(?)",
                     [str(directory / 'arrest_observations.json')])
        conn.execute("""create table stg_arrests as
            select trim(arrest_number) as arrest_number,
                   case when upper(trim(offense_type)) in ('', '-') then null else upper(trim(offense_type)) end as offense_type,
                   offense_type as offense_type_original,
                   case when upper(trim(nibrs_description)) in ('', '-') then null else upper(trim(nibrs_description)) end as nibrs_description,
                    timestamp '2026-01-01' as ingested_at, null::varchar as source_file, null::varchar as batch_id,
                   frequency::bigint as source_frequency
            from observations""")
        conn.execute('create table arrest as select distinct arrest_number from stg_arrests where arrest_number is not null')
        conn.execute("create table crime_labels as select * from read_json_auto(?)", [str(directory / 'crime_nibrs.json')])
        # No se inventa una última versión: esta comprobación exige que cada código tenga una sola descripción.
        assert conn.execute("""select count(*) from (
            select nibrs_offense_code from crime_labels where nibrs_offense_code <> '-'
            group by 1 having count(distinct upper(trim(nibrs_offense_code_description))) <> 1)""").fetchone()[0] == 0
        nibrs_key = dbt_utils_namespace().generate_surrogate_key(['upper(trim(nibrs_offense_code))'])
        conn.execute(translate(f"""create table nibrs as
            select distinct {nibrs_key} as nibrs_key,
                   upper(trim(nibrs_offense_code)) as offense_code,
                   upper(trim(nibrs_offense_code_description)) as offense_description
            from crime_labels where nibrs_offense_code <> '-' and nibrs_offense_code is not null"""))
        for name, path in MODELS.items():
            conn.execute(f'create table {name} as ' + translate(render(path)))
            if name in ('offense_types', 'dim_offense_types'):
                assert_catalog_schema(conn, name)
        export_csv(conn, directory / 'offense_type_profile.csv', """
            select t.*, s.source_rows
            from offense_types t
            join (select upper(trim(offense_type)) as offense_type, sum(frequency::int) as source_rows
                  from observations group by 1) s using (offense_type)
            order by s.source_rows desc, t.offense_type""")
        export_csv(conn, directory / 'nibrs_correspondence.csv', """
            select s.nibrs_description, s.source_rows, count(n.nibrs_key) as matching_codes,
                   min(n.offense_code) as offense_code, min(n.nibrs_key) as nibrs_key
            from (select nibrs_description, sum(source_frequency) as source_rows from stg_arrests group by 1) s
            left join nibrs n on n.offense_description = s.nibrs_description
            group by s.nibrs_description, s.source_rows order by s.nibrs_description""")
        arrest_offense_id = dbt_utils_namespace().generate_surrogate_key(
            ['arrest_number', 'offense_type', 'nibrs_description'])
        conn.execute(translate(f"""create table baseline as
            select distinct arrest_number, offense_type, nibrs_description,
                   {arrest_offense_id} as arrest_offense_id
            from stg_arrests where offense_type is not null or nibrs_description is not null"""))
        conn.execute('create table fact_arrests as select * from arrest')
        # Ejecuta las pruebas singulares del proyecto sobre los modelos materializados localmente.
        singulars = [
            'arrest_offenses_preserved', 'offense_types_coverage', 'offense_types_parse_contract',
            'offense_type_references_resolved',
            'arrest_nibrs_correspondence', 'arrest_nibrs_resolution',
            'gold/arrest_offense_counts_preserved', 'gold/offense_type_originals_preserved',
        ]
        for name in singulars:
            # DuckDB ya tiene arrays tipados; Snowflake ARRAY_CONTAINS necesita TO_VARIANT.
            expression = sqlglot.parse_one(render(f'tests/singular/{name}.sql'), read='snowflake')
            expression = expression.transform(
                lambda node: node.this.copy() if isinstance(node, exp.ToVariant) else node)
            failures = conn.execute(expression.sql(dialect='duckdb')).fetchall()
            assert not failures, (name, failures[:5])
            print('PASS:', name)
        before = conn.execute('select count(*) from baseline').fetchone()[0]
        after = conn.execute('select count(*) from arrest_offenses').fetchone()[0]
        assert before == after
        assert conn.execute('select count(*) = count(distinct arrest_offense_id) from arrest_offenses').fetchone()[0]
        assert conn.execute('select count(*) = count(distinct offense_type_id) from offense_types').fetchone()[0]
        assert conn.execute('select count(*) from offense_types where offense_type_id <> md5(offense_type)').fetchone()[0] == 0
        for foreign_key, parent in [('offense_type_id', 'offense_types'), ('nibrs_key', 'nibrs')]:
            assert conn.execute(f"""select count(*) from arrest_offenses d left join {parent} p using ({foreign_key})
                where d.{foreign_key} is not null and p.{foreign_key} is null""").fetchone()[0] == 0
        conn.execute('create table first_pass as select offense_type_id, offense_type from offense_types')
        conn.execute('create or replace table offense_types as ' + translate(render(MODELS['offense_types'])))
        assert not conn.execute('select * from first_pass except select offense_type_id, offense_type from offense_types').fetchall()
        report = {
            'scope': 'Public snapshot; SQL transpiled to DuckDB, NOT a Snowflake deployment validation',
            'source_rows': conn.execute('select sum(frequency::int) from observations').fetchone()[0],
            'arrests_before': conn.execute('select count(*) from arrest').fetchone()[0],
            'arrests_after': conn.execute('select count(*) from fact_arrests').fetchone()[0],
            'offenses_before': before, 'offenses_after': after,
            'offense_types_before': conn.execute('select count(distinct offense_type) from stg_arrests').fetchone()[0],
            'offense_types_after': conn.execute('select count(*) from offense_types').fetchone()[0],
            'parse_status': dict(conn.execute('select parse_status, count(*) from offense_types group by 1').fetchall()),
            'nibrs_descriptions': conn.execute('select count(distinct nibrs_description) from stg_arrests').fetchone()[0],
            'nibrs_null_source_rows': conn.execute("select sum(frequency::int) from observations where nibrs_description is null or upper(trim(nibrs_description)) in ('', '-')").fetchone()[0],
            'nibrs_codes': conn.execute('select count(*) from nibrs').fetchone()[0],
            'nibrs_status': dict(conn.execute('select nibrs_match_status, count(*) from arrest_offenses group by 1').fetchall()),
            'offenses_per_arrest': conn.execute('select n, count(*) from (select a.arrest_number, count(d.arrest_offense_id) as n from arrest a left join arrest_offenses d using (arrest_number) group by 1) group by n order by n').fetchall(),
        }
        (directory / 'local_validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False, indent=2))


def real_csv_tests(path, directory):
    """Comprueba TODOS los valores del CSV real y exporta una comparación por valor."""
    with path.open(encoding='utf-8-sig', newline='') as file:
        texts = [row['OFFENSE_TYPE'] for row in csv.DictReader(file)]
    assert texts and all(text not in (None, '', '-') for text in texts), 'Se espera el catálogo de textos no nulos, no marcadores RAW.'
    directory.mkdir(parents=True, exist_ok=True)
    originals = {}
    for text in texts:
        originals.setdefault(text.strip(' ').upper(), set()).add(text)
    with duckdb.connect() as conn:
        fixture(conn, 'stg_arrests', [dict(offense_type=text.strip(' ').upper(), offense_type_original=text,
                                         ingested_at='2026-01-01', source_file=None, batch_id=None) for text in texts])
        for name in ('offense_types', 'dim_offense_types'):
            conn.execute(f'create table {name} as ' + translate(render(MODELS[name])))
            assert_catalog_schema(conn, name)
        for actual, expected in [('offense_types', 'dim_offense_types'), ('dim_offense_types', 'offense_types')]:
            columns = ', '.join(CATALOG_COLUMNS)
            assert not conn.execute(f'select {columns} from {actual} except all select {columns} from {expected}').fetchall()
        for name in ('offense_types_coverage', 'offense_types_parse_contract', 'gold/offense_type_originals_preserved'):
            expression = sqlglot.parse_one(render(f'tests/singular/{name}.sql'), read='snowflake')
            expression = expression.transform(lambda node: node.this.copy() if isinstance(node, exp.ToVariant) else node)
            assert not conn.execute(expression.sql(dialect='duckdb')).fetchall(), name
        cursor = conn.execute('select * from offense_types')
        columns = [column[0] for column in cursor.description]
        rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
        assert len(rows) == len(originals)
        assert len({row['offense_type_id'] for row in rows}) == len(rows)
        source_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        if source_hash == '2153796dec6ee35abb5b1d7e33eb9b57a4713cf996acd4ef02a45f2b9b41bd0a':
            assert len(rows) == 728
            assert Counter(row['parse_status'] for row in rows) == {
                'parsed': 720, 'administrative': 3, 'review_required': 5,
            }
        for row in rows:
            text = row['offense_type']
            assert text is not None and row['offense_type_id'] == hashlib.md5(text.encode()).hexdigest()
            assert set(row['offense_type_original_values']) == originals[text], text
            code = row['legal_code']
            secondary = row['secondary_legal_code']
            for fragment in (code, secondary):
                assert fragment is None or fragment in text, (text, fragment)
            if code:
                end = text.index(code) + len(code)
                if secondary:
                    end = text.index(secondary, end) + len(secondary)
                expected_description = text[end:].strip(' ')
                if expected_description.startswith('|'):
                    expected_description = expected_description[1:].strip(' ')
            elif row['legal_source'] is not None and '|' in text:
                expected_description = text.split('|', 1)[1].strip(' ')
            elif row['external_code'] is not None:
                expected_description = text.split('|', 1)[1].strip(' ')
            else:
                expected_description = text
            assert row['offense_description'] == (expected_description or None), text
        # Referencia histórica deliberadamente fija: clasificación del parser anterior.
        conn.execute("""create table previous as
            with labels as (
                select offense_type, trim(split_part(offense_type, '|', 2)) as label,
                    regexp_full_match(offense_type,
                    '^(RCW|SMC)[[:space:]]*-[[:space:]]*[0-9]+[A-Z]?([.][0-9A-Z]+)+([(][0-9A-Z]+[)])*[[:space:]]*[|][^|]+$') as has_reference
                from offense_types)
            select offense_type, case
                when has_reference and len(string_split(label, ' - ')) = 2
                     and trim(split_part(label, ' - ', 1)) not in ('', '-')
                     and trim(split_part(label, ' - ', 2)) not in ('', '-') then 'parsed'
                when has_reference and label not in ('', '-') and len(string_split(label, ' - ')) = 1 then 'partial'
                else 'review_required' end as previous_parse_status
            from labels""")
        export_csv(conn, directory / 'offense_types_comparison.csv', """
            select t.*, p.previous_parse_status from offense_types t join previous p using (offense_type)
            order by t.parse_status desc, t.offense_type""")
        export_csv(conn, directory / 'category_prefix_review.csv', """
            select trim(split_part(offense_description, ' - ', 1)) as literal_prefix,
                   offense_category, count(*) as value_count
            from offense_types where contains(offense_description, ' - ')
            group by 1, 2 order by value_count desc, literal_prefix""")
        # Repetición del SQL: la mejora del parser nunca redefine la identidad.
        conn.execute('create table repeated as ' + translate(render(MODELS['offense_types'])))
        assert not conn.execute('select offense_type_id, offense_type from offense_types except select offense_type_id, offense_type from repeated').fetchall()
        report = {
            'scope': 'Real CSV; Snowflake SQL transpiled to DuckDB; no Snowflake deployment',
            'source': str(path.resolve()), 'sha256': source_hash,
            'catalog_columns': columns,
            'original_distinct_values': len(set(texts)), 'catalog_values': len(rows),
            'pipe_distribution': dict(Counter(str(min(text.count('|'), 2)) for text in texts)),
            'old_status': dict(conn.execute('select previous_parse_status, count(*) from previous group by 1').fetchall()),
            'new_status': dict(conn.execute('select parse_status, count(*) from offense_types group by 1').fetchall()),
            'categories': dict(conn.execute("select coalesce(offense_category, 'NULL'), count(*) from offense_types group by 1").fetchall()),
            'legal_references_without_explicit_category': conn.execute('select count(*) from offense_types where legal_code is not null and offense_category is null').fetchone()[0],
            'primary_legal_codes': sum(row['legal_code'] is not None for row in rows),
            'secondary_legal_codes': sum(row['secondary_legal_code'] is not None for row in rows),
            'external_codes': sum(row['external_code'] is not None for row in rows),
            'external_without_legal_code': sum(row['external_code'] is not None and row['legal_code'] is None for row in rows),
            'tails_with_hyphen_after_first_pipe': sum(' - ' in text.split('|', 1)[1] for text in texts if '|' in text),
            'descriptions_with_hyphen_after_legal_extraction': sum(' - ' in row['offense_description'] for row in rows if row['offense_description']),
            'review_required': [row['offense_type'] for row in rows if row['parse_status'] == 'review_required'],
            'missing_originals': 0, 'null_catalog_texts': 0, 'unstable_keys': 0,
            'nonliteral_codes': 0, 'truncated_descriptions': 0,
        }
        (directory / 'real_csv_validation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot-dir', type=Path)
    parser.add_argument('--download-snapshot', type=Path, help='Descarga explícita del origen público y ejecuta la regresión local.')
    parser.add_argument('--offense-types-csv', type=Path, help='CSV real con la columna OFFENSE_TYPE; verifica todos sus valores.')
    parser.add_argument('--output-dir', type=Path, default=Path('/tmp/opencode/offense-parser-v2'))
    args = parser.parse_args()
    if args.snapshot_dir and args.download_snapshot:
        parser.error('Usa --snapshot-dir o --download-snapshot, no ambos.')
    if not (args.snapshot_dir or args.download_snapshot or args.offense_types_csv):
        parser.error('Indica --snapshot-dir, --download-snapshot o --offense-types-csv.')
    if args.download_snapshot:
        download_snapshot(args.download_snapshot)
    directory = args.snapshot_dir or args.download_snapshot
    if directory:
        snapshot_tests(directory)
    if args.offense_types_csv:
        real_csv_tests(args.offense_types_csv, args.output_dir)
