"""Regresión sintética SQLite del mart unificado; no conecta con Snowflake.

Opcional: --legacy-dir RUTA contrasta las proyecciones con los tres SQL anteriores.
"""
import argparse
import math
from pathlib import Path
import sqlite3

from jinja2 import Environment, StrictUndefined
import sqlglot
import yaml


ROOT = Path(__file__).resolve().parents[2]
MODEL = 'mart_crimes_pet_licenses'


def sql(path):
    text = Environment(undefined=StrictUndefined).from_string(path.read_text()).render(ref=lambda n: n)
    return sqlglot.transpile(text, read='snowflake', write='sqlite')[0]


def fixture():
    conn = sqlite3.connect(':memory:')
    conn.row_factory = sqlite3.Row
    conn.create_function('YEAR', 1, lambda d: int(d[:4]) if d else None)
    conn.executescript('''
        create table fact_crimes(crime_id, offense_date, address_id, nibrs_key);
        create table dim_nibrs(nibrs_key, offense_code);
        create table dim_address(address_id, cp);
        create table bridge_crime_shooting_types(crime_id, shooting_type_id);
        create table dim_licenses(cp, license_issue_date, species);
        create table dim_postal_codes(cp, geography, boundary_version);
        insert into dim_postal_codes values ('98101','polygon-a','v1'),('98102',NULL,NULL),('98103','polygon-c','v1');
        insert into dim_address values ('a','98101'),('b','98102'),('outside','99999'),('missing',NULL);
    ''')
    codes = ['240', '120', '09A', '09B', '09C', '23A', '23B', '23H', '23F']
    conn.executemany('insert into dim_nibrs values (?,?)', [(c,c) for c in codes])
    crimes = [
        ('c1','2024-01-01','a','240'),('c2','2024-01-02','a','120'),('c3','2024-01-03','a','09A'),
        ('c4','2024-01-04','b',None),('c5','2024-01-05','b','09B'),('c6','2024-01-06','b','09C'),
        ('c7','2024-01-07','a','23A'),('c8','2024-01-08','a','23B'),('c9','2024-01-09','a','23H'),
        ('c10','2024-01-10','a','23F'),('c11','2024-01-11','a',None),
        ('c12','2024-01-12','outside','240'),('c13',None,'a','240'),('c14','2024-01-14',None,'240'),
        ('c15','2025-01-01','a','240'),('c16','2026-01-01','a','120'),('c17','2024-01-17','missing','240')
    ]
    conn.executemany('insert into fact_crimes values (?,?,?,?)', crimes)
    conn.executemany('insert into bridge_crime_shooting_types values (?,?)',
                     [('c1','x'),('c1','y'),('c2','x'),('c3','x'),('c3','y'),('c4','x'),('c13','x')])
    conn.executemany('insert into dim_licenses values (?,?,?)', [
        ('98101','2024-01-01','DOG'),('98101','2024-01-02','DOG'),('98101','2024-01-03','CAT'),
        ('98101','2024-01-04','GOAT'),('98101','2024-01-05','PIG'),('98102','2024-01-06','BIRD'),
        ('98101','2025-01-01','RABBIT'),('98101','2023-01-01','DOG'),
        ('98101',None,'DOG'),(None,'2024-01-01','DOG')])
    return conn


def check(legacy_dir=None):
    conn = fixture()
    model_sql = sql(ROOT / 'models/gold/marts' / (MODEL + '.sql'))
    conn.execute('create table ' + MODEL + ' as ' + model_sql)
    rows = {(r['cp'],r['year']): dict(r) for r in conn.execute('select * from ' + MODEL)}
    assert len(rows) == 6
    assert {y for _, y in rows} == {2024,2025}  # Años comunes, antes de filtrar especie o delito.
    for key, expected in [(('98101',2024),(1,4,3)),(('98102',2024),(0,0,3)),(('98101',2025),(1,0,0))]:
        r = rows[key]
        assert tuple(r[k] for k in ('vehicle_theft_count','theft_count','shooting_or_homicide_count')) == expected
    a = rows['98101',2024]
    assert a['pet_license_count'] == 5 and a['dog_license_count'] == 2
    assert a['cumulative_dog_license_count'] == 3  # También incluye 2023, sin delitos.
    assert a['cumulative_cat_license_count'] == 1
    assert math.isclose(a['dog_license_share'],.4)
    for cp in ('98102','98103'):
        assert rows[cp,2024]['pet_license_count'] == 0
        assert rows[cp,2024]['cat_license_share'] is None
    assert rows['98102',2024]['geography'] is None
    assert rows['98103',2024]['vehicle_theft_count'] == 0
    assert rows['98101',2025]['pet_license_count'] == 0
    assert rows['98101',2025]['cumulative_dog_license_count'] == 3
    reconciliation = sql(ROOT / 'tests/singular/gold/mart_crimes_pet_licenses_reconciliation.sql')
    assert not conn.execute(reconciliation).fetchall()
    properties = yaml.safe_load((ROOT / 'models/gold/marts/_marts.yml').read_text())
    config = next(m for m in properties['models'] if m['name'] == MODEL)
    expressions = [t['dbt_utils.expression_is_true']['arguments']['expression']
                   for t in config['data_tests'] if 'dbt_utils.expression_is_true' in t]
    assert len(expressions) == 2
    assert all(not conn.execute(f'select * from {MODEL} where not ({e})').fetchall() for e in expressions)
    for column in ('vehicle_theft_count','theft_count','shooting_or_homicide_count','dog_license_count','cumulative_dog_license_count'):
        conn.execute('savepoint negative')
        conn.execute(f'update {MODEL} set {column} = {column} + 10 where cp = ? and year = ?', ('98101',2024))
        assert conn.execute(reconciliation).fetchall()
        conn.execute('rollback to negative')
        conn.execute('release negative')
    conn.execute('savepoint share')
    conn.execute(f"update {MODEL} set dog_license_share = NULL where cp='98101' and year=2024")
    assert conn.execute(f'select * from {MODEL} where not ({expressions[1]})').fetchall()
    conn.execute('rollback to share')
    conn.execute('release share')
    if legacy_dir:
        for path in legacy_dir.glob('*pet_licenses.sql'):
            original = [dict(r) for r in conn.execute(sql(path))]
            assert len(original) == len(rows)
            for r in original:
                merged = rows[r['cp'],r['year']]
                assert all(merged[k] == v for k,v in r.items()), path.name
        print('Las proyecciones coinciden con los tres SQL anteriores, incluidas licencias y cartografía.')
    return conn


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-dir', type=Path)
    args = parser.parse_args()
    check(args.legacy_dir)
    print('OK: CP-año, ceros, años comunes, especies, solapamientos, etiquetas múltiples y NIBRS ausente.')
