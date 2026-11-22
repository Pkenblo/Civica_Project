"""Regresión SQLite del mapa con contexto ACS; no conecta con Snowflake.

Ejecutar: python3 tests/integration/mart_crimes_socioeconomic_check.py
Requiere Jinja2, PyYAML y sqlglot. Reutiliza el catálogo sintético de detenciones
para contrastar ambos marts; las geometrías son etiquetas, no geometrías reales.
"""

from mart_arrest_socioeconomic_check import ROOT, database, sql_file

import yaml


MODEL = "mart_crimes_socioeconomic"


def fixture():
    conn = database()
    # WKB sintético: comprueba identidad y NULL, no geometrías reales.
    conn.create_function("ST_ASWKB", 1, lambda value: value.encode() if value is not None else None)
    conn.executescript("""
        create table fact_crimes (
            crime_id text, offense_date text, address_id text,
            offense_classification_id text, nibrs_key text
        );
        create table dim_offense_classification (
            offense_classification_id text, offense_category text, offense_sub_category text
        );
        create table dim_nibrs (nibrs_key text, offense_code text, offense_description text);
        insert into dim_offense_classification values ('o1', 'THEFT', 'MOTOR VEHICLE THEFT');
        insert into dim_nibrs values ('n1', '240', 'Motor Vehicle Theft');
        update dim_census_socioeconomic set median_household_income=150000 where cp='98114';
        insert into dim_address values
            ('no_cp', NULL, 'no_match', 'XX NO CP AVE', 47.61234, -122.33456, NULL, NULL, NULL, 0, 0, 0),
            ('invalid', '98101', 'invalid_coordinates', 'XX INVALID AVE', 999, -122.33456, NULL, NULL, NULL, 0, 0, 1),
            ('out_of_range', '98101', 'matched', 'XX RANGE AVE', 999, -122.33456, NULL, NULL, NULL, 0, 0, 0),
            ('no_block', '98101', 'matched', NULL, 47.61234, -122.33456, NULL, NULL, NULL, 0, 0, 0),
            ('hidden', '98101', 'redacted', 'XX HIDDEN AVE', 47.61234, -122.33456, NULL, NULL, NULL, 1, 0, 0);
    """)
    events = [(f"c{i}", "2024-01-01", f"a{i}", "o1", "n1") for i in range(1, 15)]
    events += [(f"extra-{i}", None, address, None, None) for i, address in enumerate([
        "a1", "a1", "redacted", "missing", "absent", "bad_cp", "no_cp",
        "invalid", "out_of_range", "no_block", "hidden",
    ])]
    conn.executemany("insert into fact_crimes values (?, ?, ?, ?, ?)", events)
    return conn


def build(conn):
    conn.execute(f"drop table if exists {MODEL}")
    conn.execute(f"create table {MODEL} as " + sql_file(f"models/gold/marts/{MODEL}.sql"))


def singular_results(conn):
    return {path.stem: len(conn.execute(sql_file(path)).fetchall())
            for path in sorted((ROOT / "tests/singular/gold").glob(f"{MODEL}_*.sql"))}


def check_yaml(conn):
    spec = next(m for m in yaml.safe_load((ROOT / "models/gold/marts/_marts.yml").read_text())["models"]
                if m["name"] == MODEL)
    for test in spec["data_tests"]:
        expression = test["dbt_utils.expression_is_true"]["arguments"]["expression"]
        assert not conn.execute(f"select 1 from {MODEL} where not ({expression})").fetchall()
    for column in spec["columns"]:
        name = column["name"]
        for test in column.get("data_tests", []):
            if test == "not_null":
                query = f"select 1 from {MODEL} where {name} is null"
            elif test == "unique":
                query = f"select 1 from {MODEL} group by {name} having count(*) > 1"
            else:
                values = test["accepted_values"]["arguments"]["values"]
                allowed = ", ".join("'" + value + "'" for value in values)
                query = f"select 1 from {MODEL} where {name} not in ({allowed})"
            assert not conn.execute(query).fetchall(), (name, test)


def main():
    conn = fixture()
    build(conn)
    check_yaml(conn)
    results = singular_results(conn)
    assert len(results) == 2 and not any(results.values()), results
    # El contexto repetido se valida una vez, sin muestrear delitos del CP.
    conn.execute(f"update {MODEL} set population=999 where cp='98101'")
    assert singular_results(conn)[f"{MODEL}_context"] == 1
    conn.execute(f"update {MODEL} set population=998 where crime_id='c1'")
    assert singular_results(conn)[f"{MODEL}_context"] == 2
    build(conn)
    rows = {row["crime_id"]: dict(row) for row in conn.execute(f"select * from {MODEL}")}
    assert len(rows) == 18
    # El contrato previo mantiene coordenadas, clasificación y fechas sin imputar.
    row = rows["c1"]
    assert row["block_address"] == "1XX TEST AVE"
    assert (row["latitude"], row["longitude"]) == (47.61234, -122.33456)
    assert row["point_geography"] == "POINT(-122.33456 47.61234)"
    assert (row["offense_category"], row["offense_sub_category"]) == ("THEFT", "MOTOR VEHICLE THEFT")
    assert (row["nibrs_code"], row["nibrs_description"], row["nibrs_category"]) == (
        "240", "Motor Vehicle Theft", "Delitos contra vehículos")
    assert rows["extra-0"]["offense_date"] is None
    assert rows["extra-0"]["nibrs_category"] == "Sin clasificar"
    for key in ["c13", "c14", "extra-5", "extra-6"]:
        assert key in rows and rows[key]["point_geography"] is not None
    assert rows["c13"]["has_socioeconomic_data"] == 0
    assert rows["c13"]["median_household_income"] is None
    assert rows["extra-5"]["cp"] == "88888" and rows["extra-5"]["has_postal_reference"] == 0
    assert rows["extra-6"]["cp"] is None and rows["extra-6"]["has_socioeconomic_data"] == 0
    assert rows["c14"]["has_socioeconomic_data"] == 1
    assert rows["c14"]["median_household_income"] == 150000  # ACS disponible, pero sin polígono.
    assert rows["c14"]["income_quintile"] is None
    capped = rows["c11"]
    for name in ["median_household_income", "median_home_value", "median_monthly_rent", "income_quintile", "income_level"]:
        assert capped[name] is None
    assert [capped[name] for name in ["income_top_coded", "home_value_top_coded", "rent_top_coded"]] == [1, 1, 1]
    assert [capped[name] for name in ["income_lower_bound", "home_value_lower_bound", "rent_lower_bound"]] == [250000, 2000000, 3500]
    assert all(row["acs_year"] == 2024 and row["acs_period"] == "2020–2024" for row in rows.values())
    for index in range(1, 11):
        assert rows[f"c{index}"]["income_quintile"] == (index + 1) // 2

    # Los dos marts comparten quintiles aunque difieran sus distribuciones de hechos.
    conn.execute("create table mart_arrest_socioeconomic as " + sql_file("models/gold/marts/mart_arrest_socioeconomic.sql"))
    assert not conn.execute(f"""
        select 1 from {MODEL} c join mart_arrest_socioeconomic a on a.cp = c.cp
        where c.income_quintile is distinct from a.income_quintile
           or c.income_level is distinct from a.income_level
    """).fetchall()
    # Las zonas sin delitos deben seguir formando parte del catálogo de quintiles.
    conn.execute("delete from fact_crimes where address_id in ('a3', 'a4', 'a5', 'a6', 'a7', 'a8', 'a9', 'a10')")
    build(conn)
    assert conn.execute(f"select income_quintile from {MODEL} where crime_id='c2'").fetchone()[0] == 1
    assert not any(singular_results(conn).values())
    conn.close()

    # Controles negativos: las pruebas detectan cambios de contexto y de grano.
    for statement, test in [
        (f"update {MODEL} set median_household_income=999 where cp='98101'", "context"),
        (f"update {MODEL} set income_quintile=5 where cp='98101'", "context"),
        (f"update {MODEL} set income_level='alto' where cp='98101'", "context"),
        (f"update {MODEL} set geography='wrong-polygon' where crime_id='c1'", "context"),
        (f"update {MODEL} set geography=NULL where crime_id='c1'", "context"),
        (f"update {MODEL} set geography='unexpected-polygon' where crime_id='c14'", "context"),
        (f"update {MODEL} set geography='unexpected-polygon' where crime_id='extra-5'", "context"),
        (f"update {MODEL} set geography='unexpected-polygon' where crime_id='extra-6'", "context"),
        ("update dim_postal_codes set geography='changed-polygon' where cp='98101'", "context"),
        (f"delete from {MODEL} where crime_id='extra-6'", "reconciliation"),
        (f"insert into {MODEL} select * from {MODEL} where crime_id='c1'", "reconciliation"),
    ]:
        conn = fixture()
        build(conn)
        conn.execute(statement)
        assert singular_results(conn)[f"{MODEL}_{test}"] > 0
        conn.close()
    # Cada atributo sigue comprobándose incluso si solo cambia un delito
    # entre los tres que comparten el CP 98101.
    for column, value in {
        "has_postal_reference": "0",
        "boundary_version": "'wrong-version'",
        "zcta_name": "'wrong-name'",
        "has_socioeconomic_data": "0",
        "median_household_income": "999",
        "income_margin_of_error": "999",
        "population": "NULL",
        "median_home_value": "999",
        "median_monthly_rent": "999",
        "income_top_coded": "1",
        "home_value_top_coded": "1",
        "rent_top_coded": "1",
        "income_lower_bound": "250000",
        "home_value_lower_bound": "2000000",
        "rent_lower_bound": "3500",
        "income_quintile": "5",
        "income_level": "'alto'",
    }.items():
        conn = fixture()
        build(conn)
        conn.execute(f"update {MODEL} set {column}={value} where crime_id='c1'")
        assert singular_results(conn)[f"{MODEL}_context"] == 1, column
        conn.close()
    for table in ["dim_postal_codes", "dim_census_socioeconomic"]:
        conn = fixture()
        conn.execute(f"insert into {table} select * from {table} where cp='98101'")
        build(conn)
        assert singular_results(conn)[f"{MODEL}_reconciliation"] > 0
        conn.close()
    conn = fixture()
    conn.execute("delete from fact_crimes")
    build(conn)
    assert conn.execute(f"select count(*) from {MODEL}").fetchone()[0] == 0
    assert not any(singular_results(conn).values())
    conn.close()
    print("OK: 18 puntos, contrato previo, contexto ACS, censura, quintiles comunes, YAML y controles negativos (SQLite sintético).")


if __name__ == "__main__":
    main()
