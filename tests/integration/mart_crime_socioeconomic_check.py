"""Regresión local del nuevo mart; no conecta con Snowflake ni ejecuta otros modelos.

Ejecutar: python tests/integration/mart_crime_socioeconomic_check.py
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
MODEL = "mart_crime_socioeconomic"
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
    conn.executescript("""
        create table fact_crimes (
            crime_id text, address_id text, offense_date text,
            offense_classification_id text, crime_count integer
        );
        create table dim_address (address_id text, cp text, cp_status text);
        create table dim_postal_codes (cp text, geography text, boundary_version text);
        create table dim_census_socioeconomic (
            cp text, zcta_name text, median_household_income integer,
            income_margin_of_error integer, population integer,
            median_home_value integer, median_monthly_rent integer,
            income_top_coded boolean, home_value_top_coded boolean, rent_top_coded boolean
        );
        create table dim_offense_classification (
            offense_classification_id text, offense_category_id text,
            offense_subcategory_id text, offense_category text, offense_sub_category text
        );
    """)
    for index in range(1, 15):
        cp = f"981{index:02d}"
        conn.execute("insert into dim_postal_codes values (?, ?, 'test')",
                     (cp, f"polygon-{cp}" if index != 14 else None))
        conn.execute("insert into dim_address values (?, ?, 'matched')", (f"a{index}", cp))
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
    conn.executemany("insert into dim_address values (?, ?, ?)", [
        ("redacted", None, "redacted"), ("missing", None, "missing_coordinates"),
        ("bad_cp", "88888", "matched"),
    ])
    conn.executemany("insert into dim_offense_classification values (?, ?, ?, ?, ?)", [
        ("robbery", "person", "robbery_sub", "PERSON", "ROBBERY"),
        ("theft", "property", "theft_sub", "PROPERTY", "THEFT"),
        ("property_only", "property", None, "PROPERTY", None),
        ("subcategory_only", None, "other_sub", None, "OTHER"),
    ])
    events = [
        ("a1", "2023-01-01", "robbery"), ("a1", "2023-01-01", "robbery"),
        ("a1", "2023-02-01", "theft"), ("a1", "2023-03-01", None),
        ("a1", "2024-01-01", "property_only"), ("a2", "2023-01-01", "theft"),
        ("a11", "2024-01-01", "robbery"), ("a12", "2023-01-01", "subcategory_only"),
        ("a13", "2024-01-01", None), ("a14", "2024-01-01", "robbery"),
        ("redacted", "2023-01-01", "robbery"), ("missing", "2023-01-01", "robbery"),
        ("absent", "2023-01-01", "robbery"), ("bad_cp", "2023-01-01", "robbery"),
        ("a1", None, "robbery"),
    ]
    conn.executemany("insert into fact_crimes values (?, ?, ?, ?, 1)",
                     [(f"crime-{i}", *event) for i, event in enumerate(events)])
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
            if test == "not_null":
                query = f"select 1 from {MODEL} where {field} is null"
            else:
                name, config = next(iter(test.items()))
                args = config["arguments"]
                if name == "relationships":
                    target = ENV.from_string("{{ " + args["to"] + " }}").render(ref=lambda name: name)
                    query = (f"select 1 from {MODEL} m where m.{field} is not null and not exists "
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
    row = conn.execute(f"select * from {MODEL} where cp='98101' and year=2023 and offense_classification_id='robbery'").fetchone()
    assert row["crime_count"] == 2 and row["postal_year_crime_count"] == 4
    assert row["crimes_per_1000"] == 20 and row["crime_share_pct"] == 50
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 140
    assert conn.execute(f"select max(crimes_per_1000) from {MODEL} where cp='98102'").fetchone()[0] is None
    zero = conn.execute(f"select * from {MODEL} where cp='98103' limit 1").fetchone()
    assert zero["crime_count"] == 0 and zero["crimes_per_1000"] == 0 and zero["crime_share_pct"] is None
    missing = conn.execute(f"select * from {MODEL} where cp='98113' limit 1").fetchone()
    assert missing["has_socioeconomic_data"] == 0 and missing["population"] is None
    assert missing["crimes_per_1000"] is None and missing["income_top_coded"] is None
    capped = conn.execute(f"select * from {MODEL} where cp='98111' limit 1").fetchone()
    assert all(capped[name] is None for name in ["median_household_income", "median_home_value", "median_monthly_rent", "income_quintile"])
    assert [capped[name] for name in ["income_lower_bound", "home_value_lower_bound", "rent_lower_bound"]] == [250000, 2000000, 3500]
    for index in range(1, 11):
        quintile = conn.execute(f"select min(income_quintile), max(income_quintile) from {MODEL} where cp=?", (f"981{index:02d}",)).fetchone()
        assert tuple(quintile) == ((index + 1) // 2,) * 2
    audit = dict(conn.execute(sql_file(f"analyses/{MODEL}_validation.sql")).fetchone())
    for field, expected in {
        "original_crime_rows": 15, "original_distinct_crimes": 15, "represented_crimes": 10,
        "crimes_with_valid_cp": 11, "crimes_with_socioeconomic_data": 10,
        "represented_postal_codes": 14, "postal_codes_without_socioeconomic_data": 1,
        "excluded_missing_location": 3, "excluded_invalid_postal_reference": 1,
        "excluded_missing_date": 1, "eligible_unclassified_crimes": 2,
        "duplicate_grain_groups": 0, "join_extra_rows": 0,
        "reconciliation_difference": 0, "unexplained_exclusions": 0,
    }.items():
        assert audit[field] == expected, (field, audit[field], expected)
    assert math.isclose(audit["geographic_coverage_pct"], 1100 / 15)
    assert math.isclose(audit["socioeconomic_coverage_pct"], 1000 / 15)

    # Pruebas negativas: los controles deben detectar multiplicación y manipulación.
    conn.execute("insert into dim_census_socioeconomic select * from dim_census_socioeconomic where cp='98101'")
    build(conn)
    broken = singular_results(conn)
    assert broken[f"{MODEL}_inputs"] > 0 and broken[f"{MODEL}_reconciliation"] > 0
    conn.close()

    for table, key, value in [
        ("dim_address", "address_id", "a1"),
        ("dim_postal_codes", "cp", "98101"),
        ("dim_offense_classification", "offense_classification_id", "robbery"),
        ("fact_crimes", "crime_id", "crime-0"),
    ]:
        conn = database()
        conn.execute(f"insert into {table} select * from {table} where {key}=?", (value,))
        build(conn)
        broken = singular_results(conn)
        assert broken[f"{MODEL}_inputs"] > 0 and broken[f"{MODEL}_reconciliation"] > 0, table
        conn.close()

    conn = database()
    build(conn)
    conn.execute(f"update {MODEL} set crimes_per_1000=999 where cp='98101'")
    assert singular_results(conn)[f"{MODEL}_metrics"] > 0
    conn.execute(f"update {MODEL} set offense_category='wrong' where cp='98101'")
    assert singular_results(conn)[f"{MODEL}_context"] > 0
    conn.execute(f"delete from {MODEL} where cp='98113' and year=2023")
    assert singular_results(conn)[f"{MODEL}_spine"] > 0
    conn.close()

    conn = database()
    conn.execute("update fact_crimes set offense_date=null")
    build(conn)
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 0
    assert not any(singular_results(conn).values())
    conn.close()
    print(json.dumps({"environment": "synthetic SQLite, not Snowflake", "yaml_tests": yaml_tests,
                      "singular_test_failures": results, "negative_controls": "passed", "audit": audit},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
