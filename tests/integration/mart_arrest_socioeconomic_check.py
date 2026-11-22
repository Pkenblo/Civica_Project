"""Regresión local del nuevo mart; no conecta con Snowflake ni ejecuta otros modelos.

Ejecutar: python tests/integration/mart_arrest_socioeconomic_check.py
Dependencias locales: jinja2, PyYAML y sqlglot. Ejecuta el SQL del modelo y sus
tests singulares traducidos a SQLite; no sustituye dbt build en Snowflake.
Las geometrías son etiquetas de prueba, no se valida el motor geoespacial.
"""

import json
import math
from pathlib import Path
import sqlite3

from jinja2 import Environment, StrictUndefined
import sqlglot
import yaml


ROOT = Path(__file__).resolve().parents[2]
MODEL = "mart_arrest_socioeconomic"
ENV = Environment(undefined=StrictUndefined)


def sql_file(path):
    rendered = ENV.from_string((ROOT / path).read_text()).render(ref=lambda name: name)
    return sqlglot.transpile(rendered, read="snowflake", write="sqlite")[0]


def database():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.create_function("YEAR", 1, lambda value: int(value[:4]) if value else None)
    conn.create_function("ST_ASWKT", 1, lambda value: value)
    conn.create_function("EQUAL_NULL", 2, lambda left, right: left == right)
    # La prueba comprueba fidelidad y reglas de NULL, no cálculos geoespaciales.
    for function in ["ST_MAKEPOINT", "ST_POINT"]:
        conn.create_function(function, 2, lambda lon, lat: f"POINT({lon} {lat})")
    conn.executescript("""
        create table fact_arrests (
            arrest_number text, address_id text, arrest_occurred_date text,
            arrest_count integer, arrest_reported_date text, subject_key text,
            arrest_occurred_date_time text
        );
        create table dim_address (
            address_id text, cp text, cp_status text, block_address text,
            latitude real, longitude real, neighborhood text, reporting_area text,
            census_block_2020 text, is_location_redacted boolean,
            has_missing_coordinates boolean, has_invalid_coordinates boolean
        );
        create table dim_postal_codes (cp text, geography text, boundary_version text);
        create table dim_census_socioeconomic (
            cp text, zcta_name text, median_household_income integer,
            income_margin_of_error integer, population integer,
            median_home_value integer, median_monthly_rent integer,
            income_top_coded boolean, home_value_top_coded boolean, rent_top_coded boolean
        );
    """)
    for index in range(1, 15):
        cp = f"981{index:02d}"
        conn.execute("insert into dim_postal_codes values (?, ?, 'test')",
                     (cp, f"polygon-{cp}" if index != 14 else None))
        conn.execute("""insert into dim_address values
                     (?, ?, 'matched', ?, 47.61234, -122.33456, 'NEIGHBORHOOD', 'RA', 'BLOCK', 0, 0, 0)""",
                     (f"a{index}", cp, f"{index}XX TEST AVE"))
        if index == 13:
            continue  # CP sin correspondencia ACS.
        income = index * 10000 if index <= 10 else (250001 if index == 11 else None)
        conn.execute("insert into dim_census_socioeconomic values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                     (cp, f"ZCTA {cp}", income, 1000, 0 if index == 2 else 100,
                      2000001 if index == 11 else 500000,
                      3501 if index == 11 else 1500,
                      index == 11, index == 11, index == 11))
    # ZCTA nacional ajena al catálogo: no debe entrar en los quintiles ni en el mart.
    conn.execute("insert into dim_census_socioeconomic values ('11111', 'external', 1, 1, 1, 1, 1, 0, 0, 0)")
    conn.executemany("insert into dim_address values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
        ("redacted", None, "redacted", None, None, None, None, None, None, 1, 0, 0),
        ("missing", None, "missing_coordinates", "XX AVAILABLE AVE", None, None, "AREA", None, None, 0, 1, 0),
        ("bad_cp", "88888", "matched", "XX OUTSIDE AVE", 47.61234, -122.33456, None, None, None, 0, 0, 0),
    ])
    events = [
        ("a1", "2023-01-01"), ("a1", "2023-01-01"),
        ("a1", "2023-02-01"), ("a1", "2023-03-01"),
        ("a1", "2024-01-01"), ("a2", "2023-01-01"),
        ("a11", "2024-01-01"), ("a12", "2023-01-01"),
        ("a13", "2024-01-01"), ("a14", "2024-01-01"),
        ("redacted", "2023-01-01"), ("missing", "2023-01-01"),
        ("absent", "2023-01-01"), ("bad_cp", "2023-01-01"),
        ("a1", None),
    ]
    # Una misma persona puede tener varias detenciones; el año de reporte no manda.
    conn.executemany("insert into fact_arrests values (?, ?, ?, 1, '2025-01-01', 'same-person', ?)",
                     [(f"arrest-{i}", *event, event[1] + " 12:34:56" if event[1] else None)
                      for i, event in enumerate(events)])
    return conn


def build(conn):
    conn.execute(f"drop table if exists {MODEL}")
    conn.execute(f"create table {MODEL} as " + sql_file(f"models/gold/marts/{MODEL}.sql"))


def singular_results(conn):
    return {path.stem: len(conn.execute(sql_file(path)).fetchall())
            for path in sorted((ROOT / "tests/singular/gold").glob(f"{MODEL}_*.sql"))}


def check_yaml_tests(conn):
    spec = yaml.safe_load((ROOT / f"models/gold/marts/_{MODEL}.yml").read_text())["models"][0]
    executed = 0
    for test in spec["data_tests"]:
        name, config = next(iter(test.items()))
        args = config["arguments"]
        if name.endswith("unique_combination_of_columns"):
            columns = ", ".join(args["combination_of_columns"])
            query = f"select 1 from {MODEL} group by {columns} having count(*) > 1"
        elif name.endswith("expression_is_true"):
            query = f"select 1 from {MODEL} where not ({args['expression']})"
        else:
            raise AssertionError(name)
        assert not conn.execute(query).fetchall(), name
        executed += 1
    for column in spec["columns"]:
        field = column["name"]
        for test in column.get("data_tests", []):
            if test == "unique":
                query = f"select 1 from {MODEL} where {field} is not null group by {field} having count(*) > 1"
            elif test == "not_null":
                query = f"select 1 from {MODEL} where {field} is null"
            else:
                name, config = next(iter(test.items()))
                args = config["arguments"]
                if name == "relationships":
                    target = ENV.from_string("{{ " + args["to"] + " }}").render(ref=lambda name: name)
                    condition = config.get("config", {}).get("where", "true")
                    query = (f"select 1 from {MODEL} m where ({condition}) and m.{field} is not null and not exists "
                             f"(select 1 from {target} d where d.{args['field']} = m.{field})")
                elif name == "accepted_values":
                    values = ", ".join("'" + v.replace("'", "''") + "'" for v in args["values"])
                    query = f"select 1 from {MODEL} where {field} not in ({values})"
                else:
                    raise AssertionError(name)
            assert not conn.execute(query).fetchall(), (field, test)
            executed += 1
    return executed


def main():
    conn = database()
    build(conn)
    results = singular_results(conn)
    assert len(results) == 5 and not any(results.values()), results
    yaml_tests = check_yaml_tests(conn)
    row = conn.execute(f"select * from {MODEL} where arrest_number='arrest-0'").fetchone()
    assert row["arrest_count"] == 1 and row["postal_year_arrest_count"] == 4
    assert row["postal_year_arrests_per_1000"] == 40
    assert row["block_address"] == '1XX TEST AVE' and row["latitude"] == 47.61234
    assert row["longitude"] == -122.33456 and row["point_geography"] is not None
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 15
    assert conn.execute(f"select count(*) from {MODEL} where year=2025").fetchone()[0] == 0
    assert conn.execute(f"select max(postal_year_arrests_per_1000) from {MODEL} where cp='98102'").fetchone()[0] is None
    assert conn.execute(f"select count(*) from {MODEL} where cp='98103'").fetchone()[0] == 0
    missing = conn.execute(f"select * from {MODEL} where cp='98113' limit 1").fetchone()
    assert missing["has_socioeconomic_data"] == 0 and missing["population"] is None
    assert missing["postal_year_arrests_per_1000"] is None and missing["income_top_coded"] is None
    capped = conn.execute(f"select * from {MODEL} where cp='98111' limit 1").fetchone()
    assert all(capped[name] is None for name in ["median_household_income", "median_home_value", "median_monthly_rent", "income_quintile"])
    assert [capped[name] for name in ["income_lower_bound", "home_value_lower_bound", "rent_lower_bound"]] == [250000, 2000000, 3500]
    for index in [1, 2]:
        quintile = conn.execute(f"select min(income_quintile), max(income_quintile) from {MODEL} where cp=?", (f"981{index:02d}",)).fetchone()
        assert tuple(quintile) == ((index + 1) // 2,) * 2
    audit = dict(conn.execute(sql_file(f"analyses/{MODEL}_validation.sql")).fetchone())
    for field, expected in {
        "original_arrest_rows": 15, "original_distinct_arrests": 15, "represented_arrests": 15,
        "arrests_with_valid_cp": 11, "arrests_with_socioeconomic_data": 10,
        "represented_postal_codes": 7, "postal_codes_without_socioeconomic_data": 1,
        "retained_without_postal_location": 3, "retained_without_postal_reference": 1,
        "retained_without_date": 1, "excluded_arrests": 0,
        "duplicate_grain_groups": 0, "join_extra_rows": 0,
        "reconciliation_difference": 0,
    }.items():
        assert audit[field] == expected, (field, audit[field], expected)
    assert math.isclose(audit["geographic_coverage_pct"], 1100 / 15)
    assert math.isclose(audit["socioeconomic_coverage_pct"], 1000 / 15)
    redacted = conn.execute(f"select * from {MODEL} where arrest_number='arrest-10'").fetchone()
    assert redacted["is_location_redacted"] == 1 and redacted["point_geography"] is None
    partial = conn.execute(f"select * from {MODEL} where arrest_number='arrest-11'").fetchone()
    assert partial["block_address"] == 'XX AVAILABLE AVE' and partial["cp"] is None
    assert partial["point_geography"] is None
    absent = conn.execute(f"select * from {MODEL} where arrest_number='arrest-12'").fetchone()
    assert absent["address_id"] == 'absent' and absent["has_address_data"] == 0
    unreferenced = conn.execute(f"select * from {MODEL} where arrest_number='arrest-13'").fetchone()
    assert unreferenced["cp"] == '88888' and unreferenced["has_postal_reference"] == 0
    assert unreferenced["point_geography"] is not None and unreferenced["postal_year_arrest_count"] is None
    undated = conn.execute(f"select * from {MODEL} where arrest_number='arrest-14'").fetchone()
    assert undated["block_address"] == '1XX TEST AVE' and undated["year"] is None
    assert undated["postal_year_arrest_count"] is None

    # Pruebas negativas: los controles deben detectar multiplicación y manipulación.
    conn.execute("insert into dim_census_socioeconomic select * from dim_census_socioeconomic where cp='98101'")
    build(conn)
    broken = singular_results(conn)
    assert broken[f"{MODEL}_inputs"] > 0 and broken[f"{MODEL}_reconciliation"] > 0
    conn.close()

    for table, key, value in [
        ("dim_address", "address_id", "a1"),
        ("dim_postal_codes", "cp", "98101"),
        ("fact_arrests", "arrest_number", "arrest-0"),
    ]:
        conn = database()
        conn.execute(f"insert into {table} select * from {table} where {key}=?", (value,))
        build(conn)
        broken = singular_results(conn)
        assert broken[f"{MODEL}_inputs"] > 0 and broken[f"{MODEL}_reconciliation"] > 0, table
        conn.close()

    conn = database()
    build(conn)
    conn.execute(f"update {MODEL} set postal_year_arrests_per_1000=999 where cp='98101'")
    assert singular_results(conn)[f"{MODEL}_metrics"] > 0
    conn.execute(f"update {MODEL} set median_household_income=999 where cp='98101'")
    assert singular_results(conn)[f"{MODEL}_context"] > 0
    conn.execute(f"update {MODEL} set latitude=0 where arrest_number='arrest-0'")
    assert singular_results(conn)[f"{MODEL}_location"] > 0
    conn.execute(f"delete from {MODEL} where arrest_number='arrest-10'")
    assert singular_results(conn)[f"{MODEL}_reconciliation"] > 0
    conn.close()

    conn = database()
    conn.execute("update fact_arrests set arrest_occurred_date=null")
    build(conn)
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 15
    assert conn.execute(f"select count(*) from {MODEL} where postal_year_arrest_count is not null").fetchone()[0] == 0
    assert not any(singular_results(conn).values())
    conn.close()

    for status in ['no_match', 'boundary', 'ambiguous', 'invalid_coordinates']:
        conn = database()
        conn.execute("""update dim_address set cp_status=?, has_missing_coordinates=0,
                     has_invalid_coordinates=?, latitude=?, longitude=-122.33456
                     where address_id='missing'""",
                     (status, status == 'invalid_coordinates', 999 if status == 'invalid_coordinates' else 47.61234))
        build(conn)
        partial = conn.execute(f"select * from {MODEL} where arrest_number='arrest-11'").fetchone()
        assert partial['cp_status'] == status and partial['cp'] is None
        assert (partial['point_geography'] is None) == (status == 'invalid_coordinates')
        assert not any(singular_results(conn).values())
        conn.close()

    conn = database()
    conn.execute("delete from fact_arrests")
    build(conn)
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 0
    assert not any(singular_results(conn).values())
    empty_audit = dict(conn.execute(sql_file(f"analyses/{MODEL}_validation.sql")).fetchone())
    assert empty_audit['original_arrest_rows'] == 0 and empty_audit['excluded_arrests'] == 0
    assert empty_audit['point_coverage_pct'] is None
    conn.close()
    print(json.dumps({"environment": "synthetic SQLite, not Snowflake", "yaml_tests": yaml_tests,
                      "singular_test_failures": results, "negative_controls": "passed", "audit": audit},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
