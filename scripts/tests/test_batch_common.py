import csv
import gzip
import io
import os
import shlex
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing, redirect_stdout
from pathlib import Path
from unittest.mock import MagicMock, patch
from urllib.parse import unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import batch_common as batch


class FakeStage:
    def __init__(self, files=None):
        self.files = dict(files or {})
        self.statements = []
        self.fail_after_put = False
        self.skip_content = None
        self.cursor = MagicMock()
        self.cursor.__enter__.return_value = self.cursor
        self.cursor.execute.side_effect = self.execute
        self.connection = MagicMock()
        self.connection.__enter__.return_value = self.connection
        self.connection.cursor.return_value = self.cursor

    def execute(self, sql):
        self.statements.append(sql)
        args = shlex.split(sql)
        if args[0] == "LIST":
            self.cursor.description = [("name",)]
            self.cursor.fetchall.return_value = [
                ("stg_seattle_batch/crimes/" + name,) for name in self.files
            ]
        elif args[0] == "PUT":
            path = Path(unquote(urlparse(args[1]).path))
            if self.skip_content is not None:
                self.files[path.name] = self.skip_content
            status = "SKIPPED" if path.name in self.files else "UPLOADED"
            self.files.setdefault(path.name, path.read_bytes())
            if self.fail_after_put:
                self.fail_after_put = False
                raise ConnectionError("Respuesta perdida después del PUT")
            self.cursor.description = [("target",), ("status",)]
            self.cursor.fetchall.return_value = [(path.name, status)]
        elif args[0] == "GET":
            name = args[1].rsplit("/", 1)[1]
            folder = Path(unquote(urlparse(args[2]).path))
            (folder / name).write_bytes(self.files[name])
            self.cursor.description = [("status",)]
            self.cursor.fetchall.return_value = [("DOWNLOADED",)]
        else:
            raise AssertionError(f"SQL inesperado: {sql}")

    def connect(self):
        return patch.object(batch, "connect_snowflake", return_value=self.connection)


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o077))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "scripts/state/crimes"
        self.header = [f"c{i}" for i in range(20)]
        self.row = [f"v{i}" for i in range(20)]
        self.other = ["nueva"] + self.row[1:]
        file_patch = patch.object(
            batch, "__file__", str(self.root / "scripts/batch_common.py")
        )
        file_patch.start()
        self.addCleanup(file_patch.stop)

    def run_batch(self, *args):
        with patch.object(sys, "argv", ["batch_crimes.py", *args]), redirect_stdout(io.StringIO()):
            batch.run("tazs-3rd5", "crimes", 20)

    def download(self, rows, header=None):
        content = io.StringIO(newline="")
        csv.writer(content).writerows([self.header if header is None else header, *rows])
        return io.BytesIO(content.getvalue().encode("utf-8"))

    def db(self):
        return closing(sqlite3.connect(self.state / "state.sqlite"))

    def initialise(self):
        with patch.object(batch, "version", return_value=100), patch.object(
            batch, "request", return_value=self.download([self.row])
        ), patch.object(batch, "upload") as upload:
            self.run_batch("--inicial-web")
            upload.assert_not_called()

    def prepare(self, rows, version=101):
        with patch.object(batch, "version", return_value=version), patch.object(
            batch, "request", return_value=self.download(rows)
        ), patch.object(batch, "upload") as upload:
            self.run_batch("--preparar")
            upload.assert_not_called()

    def finish(self):
        with patch.object(batch, "prepare", side_effect=AssertionError("No descargar otra vez")), patch.object(batch, "upload"):
            self.run_batch()

    def test_web_baseline_saved_without_upload(self):
        self.initialise()
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "version"), 100)
            self.assertEqual(batch.get_meta(db, "baseline")["total"], 1)
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 1)
        with gzip.open(self.state / "crimes_baseline_100.csv.gz", "rt", newline="") as source:
            self.assertEqual(list(csv.reader(source)), [self.header, self.row])

    def test_prepare_alias_does_not_upload(self):
        self.initialise()
        with patch.object(batch, "version", return_value=101), patch.object(
            batch, "request", return_value=self.download([self.row, self.other])
        ), patch.object(batch, "upload") as upload:
            self.run_batch("--prepare")
            upload.assert_not_called()
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "pending")["changed"], 1)

    def test_manual_run_creates_private_files(self):
        os.umask(0o022)
        self.initialise()
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        for path in self.state.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600, path.name)

    def test_baseline_refuses_reinitialization(self):
        self.initialise()
        with patch.object(batch, "request", side_effect=AssertionError("No descargar")):
            with self.assertRaisesRegex(ValueError, "Ya existe estado"):
                self.run_batch("--inicial-web")

    def test_changed_source_rolls_back_baseline(self):
        with patch.object(batch, "version", side_effect=[100, 101]), patch.object(
            batch, "request", return_value=self.download([self.row])
        ):
            with self.assertRaisesRegex(RuntimeError, "cambió durante"):
                self.run_batch("--inicial-web")
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "header"))
            self.assertEqual(db.execute("SELECT COUNT(*) FROM previous").fetchone()[0], 0)
        self.assertEqual(list(self.state.glob("*.gz*")), [])

    def test_invalid_baseline_schema_rolls_back(self):
        with patch.object(batch, "version", return_value=100), patch.object(
            batch, "request", return_value=self.download([], header=["incorrecta"])
        ):
            with self.assertRaisesRegex(ValueError, "esquema"):
                self.run_batch("--inicial-web")
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "header"))
        self.assertEqual(list(self.state.glob("*.gz*")), [])

    def test_empty_baseline_is_rejected(self):
        with patch.object(batch, "version", return_value=100), patch.object(
            batch, "request", return_value=self.download([])
        ):
            with self.assertRaisesRegex(ValueError, "vacío"):
                self.run_batch("--inicial-web")
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "version"))

    def test_unchanged_version_does_not_download_or_upload(self):
        self.initialise()
        with patch.object(batch, "version", return_value=100), patch.object(
            batch, "request", side_effect=AssertionError("No descargar")
        ), patch.object(batch, "upload") as upload:
            self.run_batch()
            upload.assert_not_called()

    def test_only_new_rows_and_extra_occurrences_are_prepared(self):
        self.initialise()
        self.prepare([self.row, self.row, self.other])
        with self.db() as db:
            pending = batch.get_meta(db, "pending")
            self.assertEqual((pending["total"], pending["changed"]), (3, 2))
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 1)
        with gzip.open(self.state / pending["file"], "rt", newline="") as source:
            self.assertEqual(list(csv.reader(source)), [self.header, self.row, self.other])

    def test_failed_upload_retains_pending_then_success_advances(self):
        self.initialise()
        self.prepare([self.row, self.other])
        with patch.object(batch, "upload", side_effect=RuntimeError("simulada")):
            with self.assertRaisesRegex(RuntimeError, "simulada"):
                self.run_batch()
        with self.db() as db:
            self.assertIsNotNone(batch.get_meta(db, "pending"))
            self.assertEqual(batch.get_meta(db, "version"), 100)
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 1)
        self.assertTrue((self.state / "crimes_101.csv.gz").exists())
        self.finish()
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "pending"))
            self.assertEqual(batch.get_meta(db, "version"), 101)
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 2)
        self.assertFalse((self.state / "crimes_101.csv.gz").exists())
        self.prepare([self.row, self.other], version=102)
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "pending")["changed"], 0)
        with patch.object(batch, "upload") as upload:
            self.run_batch()
            upload.assert_not_called()

    def test_disappeared_then_reappearing_rows_are_not_resent(self):
        self.initialise()
        self.prepare([self.row, self.row, self.other])
        self.finish()
        self.prepare([self.other], version=102)
        self.finish()
        self.prepare([self.row, self.row, self.other], version=103)
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "pending")["changed"], 0)
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 3)

    def test_changed_source_during_prepare_keeps_known_rows(self):
        self.initialise()
        with patch.object(batch, "version", side_effect=[101, 102]), patch.object(
            batch, "request", return_value=self.download([self.row, self.other])
        ):
            with self.assertRaisesRegex(RuntimeError, "cambió durante"):
                self.run_batch("--preparar")
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "pending"))
            self.assertEqual(batch.get_meta(db, "version"), 100)
            self.assertEqual(db.execute("SELECT SUM(n) FROM previous").fetchone()[0], 1)
        self.assertFalse((self.state / "crimes_101.csv.gz").exists())

    def test_upload_continues_stage_names_without_overwriting(self):
        self.initialise()
        self.prepare([self.row, self.other])
        stage = FakeStage({"crimes_101.csv.gz": b"anterior", "crimes_200.csv.gz": b"ultimo"})
        with stage.connect():
            self.run_batch()
        self.assertEqual(stage.files["crimes_101.csv.gz"], b"anterior")
        self.assertEqual(stage.files["crimes_200.csv.gz"], b"ultimo")
        self.assertIn("crimes_201.csv.gz", stage.files)
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "last_upload_number"), 201)
            self.assertEqual(batch.get_meta(db, "version"), 101)
        put = next(sql for sql in stage.statements if sql.startswith("PUT "))
        self.assertIn("AUTO_COMPRESS=FALSE OVERWRITE=FALSE", put)

    def test_upload_uses_source_version_when_newer_than_stage(self):
        self.initialise()
        self.prepare([self.row, self.other], version=300)
        stage = FakeStage({"crimes_200.csv.gz": b"anterior"})
        with stage.connect():
            self.run_batch()
        self.assertIn("crimes_300.csv.gz", stage.files)

    def test_upload_remembers_counter_even_when_stage_is_purged(self):
        self.initialise()
        self.prepare([self.row, self.other])
        with self.db() as db, db:
            batch.set_meta(db, "last_upload_number", 500)
        stage = FakeStage()
        with stage.connect():
            self.run_batch()
        self.assertIn("crimes_501.csv.gz", stage.files)

    def test_interrupted_upload_is_verified_not_uploaded_twice(self):
        self.initialise()
        self.prepare([self.row, self.other])
        stage = FakeStage({"crimes_200.csv.gz": b"anterior"})
        stage.fail_after_put = True
        with stage.connect():
            with self.assertRaisesRegex(ConnectionError, "Respuesta perdida"):
                self.run_batch()
            with self.db() as db:
                pending = batch.get_meta(db, "pending")
                self.assertEqual(pending["upload_file"], "crimes_201.csv.gz")
                self.assertEqual(batch.get_meta(db, "version"), 100)
            self.run_batch()
        self.assertEqual(sum(sql.startswith("PUT ") for sql in stage.statements), 1)
        self.assertEqual(sum(sql.startswith("GET ") for sql in stage.statements), 1)
        with self.db() as db:
            self.assertIsNone(batch.get_meta(db, "pending"))
            self.assertEqual(batch.get_meta(db, "version"), 101)

    def test_existing_retry_with_different_content_is_not_accepted(self):
        self.initialise()
        self.prepare([self.row, self.other])
        stage = FakeStage()
        stage.fail_after_put = True
        with stage.connect():
            with self.assertRaises(ConnectionError):
                self.run_batch()
            stage.files["crimes_101.csv.gz"] = b"otro contenido"
            with self.assertRaisesRegex(RuntimeError, "verificar el contenido"):
                self.run_batch()
        with self.db() as db:
            self.assertIsNotNone(batch.get_meta(db, "pending"))
            self.assertEqual(batch.get_meta(db, "version"), 100)
        self.assertEqual(sum(sql.startswith("PUT ") for sql in stage.statements), 1)

    def test_skipped_upload_is_not_success_if_content_differs(self):
        self.initialise()
        self.prepare([self.row, self.other])
        stage = FakeStage()
        stage.skip_content = b"archivo de otro proceso"
        with stage.connect():
            with self.assertRaisesRegex(RuntimeError, "verificar el contenido"):
                self.run_batch()
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "version"), 100)
            self.assertIsNotNone(batch.get_meta(db, "pending"))

    def test_skipped_upload_is_accepted_only_after_content_verification(self):
        self.initialise()
        self.prepare([self.row, self.other])
        stage = FakeStage()
        stage.skip_content = (self.state / "crimes_101.csv.gz").read_bytes()
        with stage.connect():
            self.run_batch()
        self.assertEqual(sum(sql.startswith("GET ") for sql in stage.statements), 1)
        with self.db() as db:
            self.assertEqual(batch.get_meta(db, "version"), 101)
            self.assertIsNone(batch.get_meta(db, "pending"))

    def test_stage_inspection_is_read_only(self):
        self.initialise()
        stage = FakeStage({"crimes_200.csv.gz": b"anterior"})
        with self.db() as db:
            before = list(db.execute("SELECT * FROM meta ORDER BY key"))
        with stage.connect():
            self.run_batch("--comprobar-stage")
        self.assertEqual(stage.statements, ["LIST @DEV_BRONZE.RAW.STG_SEATTLE_BATCH/crimes/"])
        with self.db() as db:
            self.assertEqual(list(db.execute("SELECT * FROM meta ORDER BY key")), before)


if __name__ == "__main__":
    unittest.main()
