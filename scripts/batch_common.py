import argparse
import csv
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path
from urllib.request import Request, urlopen


def digest(row):
    value = json.dumps(row, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def get_meta(db, key):
    row = db.execute(
        "SELECT value FROM meta WHERE key = ?", (key,)
    ).fetchone()
    return json.loads(row[0]) if row else None


def set_meta(db, key, value):
    db.execute(
        "INSERT OR REPLACE INTO meta VALUES (?, ?)",
        (key, json.dumps(value)),
    )


def request(url):
    req = Request(url, headers={"User-Agent": "CivicaBatch/1.0"})
    return urlopen(req, timeout=120)


def version():
    with request(URL + ".json") as response:
        return int(json.load(response)["rowsUpdatedAt"])


def count_row(db, table, row):
    if len(row) != N_COLUMNS:
        raise ValueError(
            f"Fila con {len(row)} columnas; se esperaban {N_COLUMNS}."
        )

    key = digest(row)

    # table solo puede ser previous o next_snapshot.
    db.execute(
        f"INSERT INTO {table} VALUES (?, 1) "
        "ON CONFLICT(hash) DO UPDATE SET n = n + 1",
        (key,),
    )
    return key


def initialise(db, filename):
    if get_meta(db, "header") is not None:
        raise ValueError(
            "Ya existe estado; no lo reinicialices entre ejecuciones."
        )

    opener = gzip.open if str(filename).endswith(".gz") else open

    with db, opener(
        filename, "rt", encoding="utf-8-sig", newline=""
    ) as source:
        rows = csv.reader(source)
        header = next(rows)

        if len(header) != N_COLUMNS:
            raise ValueError(
                "El CSV inicial no corresponde a este dataset."
            )

        for row in rows:
            count_row(db, "previous", row)

        set_meta(db, "header", header)

    print("Base inicial registrada. No se ha subido ningún archivo.")


def initialise_web(db):
    if get_meta(db, "header") is not None:
        raise ValueError(
            "Ya existe estado; no lo reinicialices entre ejecuciones."
        )

    current_version = version()
    output = ROOT / f"{NAME}_baseline_{current_version}.csv.gz"
    temporary = output.with_name(output.name + ".part")
    if output.exists() or temporary.exists():
        raise FileExistsError(f"Ya existe una descarga base: {output}")

    total = 0
    published = False
    print(f"Descargando la base oficial de {NAME}...", flush=True)
    try:
        with db:
            db.execute("DELETE FROM previous")
            with request(URL + "/rows.csv?accessType=DOWNLOAD") as response:
                with io.TextIOWrapper(
                    response, encoding="utf-8-sig", newline=""
                ) as source, gzip.open(
                    temporary, "xt", encoding="utf-8", newline=""
                ) as target:
                    rows = csv.reader(source)
                    header = next(rows)
                    if len(header) != N_COLUMNS:
                        raise ValueError("El CSV oficial no tiene el esquema esperado.")
                    writer = csv.writer(target)
                    writer.writerow(header)
                    for row in rows:
                        count_row(db, "previous", row)
                        writer.writerow(row)
                        total += 1
                        if total % 100000 == 0:
                            print(f"{NAME}: {total} filas registradas.", flush=True)

            if not total:
                raise ValueError("El CSV oficial está vacío; no se creará la base.")
            if version() != current_version:
                raise RuntimeError(
                    "El origen cambió durante la descarga; vuelve a ejecutar."
                )

            set_meta(db, "header", header)
            set_meta(db, "version", current_version)
            set_meta(db, "baseline", {
                "version": current_version,
                "file": output.name,
                "total": total,
            })
            temporary.rename(output)
            published = True
    except BaseException:
        temporary.unlink(missing_ok=True)
        if published:
            output.unlink(missing_ok=True)
        raise

    print(
        f"Base de {NAME} registrada: {total} filas. CSV guardado en {output}. "
        "No se ha subido ningún archivo.",
        flush=True,
    )


def prepare(db):
    current_version = version()

    if current_version == get_meta(db, "version"):
        print("El origen no ha cambiado.")
        return None

    output = ROOT / f"{NAME}_{current_version}.csv.gz"
    total = changed = 0

    try:
        with db:
            db.execute("DELETE FROM next_snapshot")

            with request(
                URL + "/rows.csv?accessType=DOWNLOAD"
            ) as response:
                with io.TextIOWrapper(
                    response, encoding="utf-8-sig", newline=""
                ) as source:
                    rows = csv.reader(source)
                    header = next(rows)

                    if header != get_meta(db, "header"):
                        raise ValueError(
                            "Ha cambiado la cabecera; revisar "
                            "el esquema antes de cargar."
                        )

                    with gzip.open(
                        output, "wt", encoding="utf-8", newline=""
                    ) as target:
                        writer = csv.writer(target)
                        writer.writerow(header)

                        for row in rows:
                            key = count_row(db, "next_snapshot", row)

                            old = db.execute(
                                "SELECT n FROM previous WHERE hash = ?",
                                (key,),
                            ).fetchone()

                            now = db.execute(
                                "SELECT n FROM next_snapshot WHERE hash = ?",
                                (key,),
                            ).fetchone()[0]

                            if now > (old[0] if old else 0):
                                writer.writerow(row)
                                changed += 1

                            total += 1

            if version() != current_version:
                raise RuntimeError(
                    "El origen cambió durante la descarga; "
                    "vuelve a ejecutar."
                )

            if not changed:
                output.unlink()

            pending = {
                "version": current_version,
                "file": output.name if changed else None,
                "changed": changed,
                "total": total,
            }

            set_meta(db, "pending", pending)

    except Exception:
        output.unlink(missing_ok=True)
        raise

    return pending


def connect_snowflake():
    import snowflake.connector

    return snowflake.connector.connect(
        connection_name="civica",
        role="DEV_INGEST_ROLE",
        login_timeout=30,
        network_timeout=120,
        enable_server_session_keep_alive_auto_detection=False,
    )


def cursor_rows(cursor):
    columns = [column[0].lower() for column in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def stage_names(cursor):
    cursor.execute("LIST " + STAGE)
    return {Path(row["name"]).name for row in cursor_rows(cursor)}


def stage_number(filename):
    match = re.fullmatch(re.escape(NAME) + r"_(\d+)\.csv\.gz", filename)
    return int(match[1]) if match else 0


def next_upload_number(db, pending, names):
    return max(
        pending["version"],
        max((stage_number(name) for name in names), default=0) + 1,
        (get_meta(db, "last_upload_number") or 0) + 1,
    )


def inspect_stage(db):
    with connect_snowflake() as connection:
        with connection.cursor() as cursor:
            names = stage_names(cursor)
    latest = max(names, key=stage_number) if names else None
    number = next_upload_number(db, {"version": get_meta(db, "version") or 0}, names)
    print(f"{STAGE}: {len(names)} archivos; último lote: {latest}.")
    print(
        f"Próximo nombre mínimo: {NAME}_{number}.csv.gz "
        "(se usará la versión del origen si es mayor)."
    )


def file_digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_staged_file(cursor, filename, checksum):
    # LIST.md5 puede corresponder al archivo cifrado; comparar el original con GET.
    with tempfile.TemporaryDirectory(prefix=".verify-", dir=ROOT) as directory:
        folder = Path(directory)
        uri = folder.as_uri().replace("'", "''")
        cursor.execute(f"GET {STAGE}{filename} '{uri}'")
        results = cursor_rows(cursor)
        downloaded = folder / filename
        if (
            len(results) != 1
            or str(results[0].get("status")).upper() != "DOWNLOADED"
            or not downloaded.is_file()
            or file_digest(downloaded) != checksum
        ):
            raise RuntimeError(
                f"No se ha podido verificar el contenido de {STAGE}{filename}. "
                "Se conserva el lote pendiente; no se confirma el avance."
            )


def upload(path, db, pending):
    checksum = file_digest(path)
    with connect_snowflake() as connection:
        with connection.cursor() as cursor:
            names = stage_names(cursor)
            filename = pending.get("upload_file")
            if filename:
                if not stage_number(filename) or pending.get("upload_sha256") != checksum:
                    raise RuntimeError("El archivo pendiente cambió después de reservar su subida.")
                if filename in names:
                    verify_staged_file(cursor, filename, checksum)
                    print(f"Lote ya subido y verificado: {STAGE}{filename}.")
                    return
            else:
                number = next_upload_number(db, pending, names)
                filename = f"{NAME}_{number}.csv.gz"
                pending["upload_file"] = filename
                pending["upload_sha256"] = checksum
                # Reservar antes del PUT: un reintento conserva nombre y contenido.
                with db:
                    set_meta(db, "pending", pending)
                    set_meta(db, "last_upload_number", number)

            # El CSV local conserva su nombre; PUT recibe una copia con el nombre reservado.
            with tempfile.TemporaryDirectory(prefix=".upload-", dir=ROOT) as directory:
                target = Path(directory) / filename
                shutil.copyfile(path, target)
                if file_digest(target) != checksum:
                    raise RuntimeError("El lote local cambió durante la preparación de la subida.")
                uri = target.as_uri().replace("'", "''")
                cursor.execute(
                    f"PUT '{uri}' {STAGE} AUTO_COMPRESS=FALSE OVERWRITE=FALSE"
                )
                results = cursor_rows(cursor)

            if (
                len(results) != 1
                or str(results[0].get("status")).upper() not in {"UPLOADED", "SKIPPED"}
                or results[0].get("target") != filename
            ):
                raise RuntimeError(f"La subida no se ha completado: {results}")
            if str(results[0]["status"]).upper() == "SKIPPED":
                verify_staged_file(cursor, filename, checksum)

    print(f"Archivo {filename} en {STAGE}: {results}")


def run(dataset, name, n_columns):
    global DATASET, NAME, N_COLUMNS, STAGE, ROOT, URL

    DATASET, NAME, N_COLUMNS = dataset, name, n_columns
    STAGE = "@DEV_BRONZE.RAW.STG_SEATTLE_BATCH/" + NAME + "/"
    # CSV e histórico se guardan junto a los scripts, en scripts/state/.
    ROOT = Path(__file__).resolve().parent / "state" / NAME
    URL = "https://data.seattle.gov/api/views/" + DATASET

    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--inicial",
        type=Path,
        help="CSV utilizado en la carga inicial de RAW",
    )
    mode.add_argument(
        "--inicial-web",
        action="store_true",
        help="Registrar el CSV oficial actual como base, sin subirlo a Snowflake",
    )
    mode.add_argument(
        "--preparar",
        "--prepare",
        action="store_true",
        help="Preparar el lote sin subirlo a Snowflake",
    )
    mode.add_argument(
        "--comprobar-stage",
        action="store_true",
        help="Consultar los nombres del stage sin subir ni modificar archivos",
    )
    args = parser.parse_args()

    # También protege los archivos creados al ejecutar un dataset manualmente.
    os.umask(0o077)
    ROOT.mkdir(parents=True, exist_ok=True)

    with closing(sqlite3.connect(
        ROOT / "run_lock.sqlite", timeout=0
    )) as lock, closing(sqlite3.connect(ROOT / "state.sqlite")) as db:
        # Impide ejecutar dos copias simultáneas del mismo dataset.
        lock.execute("BEGIN EXCLUSIVE")

        for table in ("previous", "next_snapshot"):
            db.execute(
                f"CREATE TABLE IF NOT EXISTS {table} "
                "(hash TEXT PRIMARY KEY, n INTEGER NOT NULL)"
            )

        db.execute(
            "CREATE TABLE IF NOT EXISTS meta "
            "(key TEXT PRIMARY KEY, value TEXT NOT NULL)"
        )
        db.commit()

        if args.comprobar_stage:
            inspect_stage(db)
            return

        if args.inicial:
            initialise(db, args.inicial)
            return

        if args.inicial_web:
            initialise_web(db)
            return

        if get_meta(db, "header") is None:
            raise ValueError(
                "Primero registra una base con --inicial o --inicial-web. "
                "No la reinicialices si ya has realizado cargas."
            )

        # Si falló una subida anterior, reutiliza el mismo archivo.
        pending = get_meta(db, "pending") or prepare(db)

        if pending is None:
            return

        print(
            f"Filas revisadas: {pending['total']}; "
            f"filas nuevas/modificadas: {pending['changed']}."
        )

        if args.preparar:
            print(
                "Lote preparado. Ejecuta sin --preparar "
                "para completar el proceso."
            )
            return

        if pending["file"]:
            path = ROOT / pending["file"]

            if not path.is_file():
                raise FileNotFoundError(
                    "Falta el archivo pendiente. "
                    "Conserva la carpeta state."
                )

            upload(path, db, pending)

        # Solo confirma el avance después de subir el archivo,
        # o cuando la comparación no encontró novedades.
        with db:
            # Histórico acumulado: una fila desaparecida y luego publicada de
            # nuevo no se vuelve a subir. n conserva su multiplicidad máxima.
            db.execute(
                "INSERT INTO previous SELECT * FROM next_snapshot WHERE true "
                "ON CONFLICT(hash) DO UPDATE SET n = MAX(previous.n, excluded.n)"
            )
            db.execute("DELETE FROM next_snapshot")
            set_meta(db, "version", pending["version"])
            db.execute("DELETE FROM meta WHERE key = 'pending'")

        if pending["file"]:
            (ROOT / pending["file"]).unlink(missing_ok=True)

        print(
            "Proceso completado. La task de Snowflake "
            "cargará los archivos a las 04:00."
        )
