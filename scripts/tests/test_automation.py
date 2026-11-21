import configparser
import fcntl
import io
import json
import os
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import closing, redirect_stdout
from http.client import HTTPException
from pathlib import Path
from unittest.mock import MagicMock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import wait_network


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="civica automation ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        for name in ("run_daily.sh", "notify_failure.sh"):
            shutil.copyfile(SCRIPTS / name, self.scripts / name)
        python = self.root / ".venv/bin/python"
        python.parent.mkdir(parents=True)
        python.symlink_to(sys.executable)
        self.calls = self.root / "calls.log"
        self.env = dict(os.environ, CALL_LOG=str(self.calls))
        stub = '''import fcntl
import os
import sys
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]
with (root / "scripts/state/daily.lock").open("a") as lock:
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        raise RuntimeError("El bloqueo global no está activo")
name = Path(__file__).stem.removeprefix("batch_")
mode = "prepare" if "--preparar" in sys.argv else "upload"
if name == "wait_network":
    name, mode = "network", "check"
with open(os.environ["CALL_LOG"], "a") as target:
    target.write(f"{mode} {name}\\n")
if mode == "prepare" and os.getenv("HOLD_PREP"):
    (root / f"{name}.pid").write_text(str(os.getpid()))
    time.sleep(60)
if mode == "prepare" and os.getenv("FAIL_PREP") == name:
    raise SystemExit(7)
if mode == "upload" and os.getenv("FAIL_UPLOAD") == name:
    raise SystemExit(8)
'''
        for name in ("wait_network.py", "batch_crimes.py", "batch_arrests.py"):
            (self.scripts / name).write_text(stub)
        for name, columns in (("crimes", 20), ("arrests", 34)):
            path = self.scripts / "state" / name / "state.sqlite"
            path.parent.mkdir(parents=True)
            with closing(sqlite3.connect(path)) as db, db:
                db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)")
                db.execute("INSERT INTO meta VALUES ('header', ?)", (json.dumps(["c"] * columns),))

    def run_script(self, name="run_daily.sh", **env):
        return subprocess.run(
            ["/usr/bin/bash", str(self.scripts / name)],
            env=dict(self.env, **env),
            text=True,
            capture_output=True,
            timeout=10,
            umask=0o022,
        )

    def read_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_runner_locks_all_phases_and_uploads_after_both_preparations(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.read_calls()
        self.assertEqual(calls[0], "check network")
        self.assertEqual(set(calls[1:3]), {"prepare crimes", "prepare arrests"})
        self.assertEqual(calls[3:], ["upload crimes", "upload arrests"])
        lock = self.scripts / "state/daily.lock"
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        with lock.open("a") as source:
            fcntl.flock(source, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_second_runner_is_skipped_before_network_or_preparation(self):
        with (self.scripts / "state/daily.lock").open("a") as source:
            fcntl.flock(source, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Ya hay una ejecución diaria", result.stdout)
        self.assertEqual(self.read_calls(), [])

    def test_missing_state_fails_before_network(self):
        (self.scripts / "state/arrests/state.sqlite").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Falta", result.stderr)
        self.assertEqual(self.read_calls(), [])

    def test_lock_errors_are_not_silently_treated_as_another_runner(self):
        folder = self.root / "bin"
        folder.mkdir()
        command = folder / "flock"
        command.write_text("#!/usr/bin/bash\nexit 64\n")
        command.chmod(0o700)
        result = self.run_script(PATH=str(folder) + os.pathsep + os.environ["PATH"])
        self.assertEqual(result.returncode, 64)
        self.assertIn("No se pudo adquirir el bloqueo diario", result.stderr)
        self.assertEqual(self.read_calls(), [])

    def test_invalid_state_fails_before_network(self):
        (self.scripts / "state/arrests/state.sqlite").write_text("not sqlite")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.read_calls(), [])

    def test_failed_preparation_prevents_both_uploads(self):
        result = self.run_script(FAIL_PREP="crimes")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No se subirá ningún lote", result.stdout)
        self.assertFalse(any(call.startswith("upload ") for call in self.read_calls()))

    def test_failed_upload_stops_runner_and_releases_lock(self):
        result = self.run_script(FAIL_UPLOAD="crimes")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("upload arrests", self.read_calls())
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls()[-1], "upload arrests")

    def test_sigterm_stops_preparations_and_releases_lock(self):
        process = subprocess.Popen(
            ["/usr/bin/bash", str(self.scripts / "run_daily.sh")],
            env=dict(self.env, HOLD_PREP="1"),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            deadline = time.monotonic() + 5
            paths = [self.root / f"{name}.pid" for name in ("crimes", "arrests")]
            while not all(path.is_file() and path.stat().st_size for path in paths):
                if process.poll() is not None or time.monotonic() >= deadline:
                    self.fail("Las preparaciones no se iniciaron correctamente")
                time.sleep(0.01)
            children = [int(path.read_text()) for path in paths]
            process.terminate()
            _, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 143, stderr)
            for pid in children:
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            self.assertFalse(any(call.startswith("upload ") for call in self.read_calls()))
            with (self.scripts / "state/daily.lock").open("a") as source:
                fcntl.flock(source, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)

    def notification_commands(self):
        folder = self.root / "bin"
        folder.mkdir()
        commands = {
            "systemctl": '''if [ "${DIAGNOSTICS_FAIL:-0}" = 1 ]; then exit 1; fi
printf 'Result=exit-code\\nExecMainCode=1\\nExecMainStatus=7\\nNRestarts=2\\n'
''',
            "journalctl": '''if [ "${DIAGNOSTICS_FAIL:-0}" = 1 ]; then exit 1; fi
echo 'Error de prueba en el journal'
''',
            "notify-send": '''printf '%s\\n' "$@" > "$NOTIFY_ARGS"
exit "${NOTIFY_FAIL:-0}"
''',
        }
        for name, content in commands.items():
            path = folder / name
            path.write_text("#!/usr/bin/bash\n" + content)
            path.chmod(0o700)
        return {
            "PATH": str(folder) + os.pathsep + os.environ["PATH"],
            "NOTIFY_ARGS": str(self.root / "notify.args"),
            "MONITOR_SERVICE_RESULT": "exit-code",
            "MONITOR_EXIT_CODE": "exited",
            "MONITOR_EXIT_STATUS": "7",
        }

    def test_notification_writes_private_diagnostic_and_persistent_alert(self):
        env = self.notification_commands()
        logs = self.root / "logs"
        logs.mkdir()
        logfile = logs / "civica-batch-error.log"
        logfile.write_text("diagnóstico anterior")
        logfile.chmod(0o644)
        result = self.run_script("notify_failure.sh", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        content = logfile.read_text()
        for expected in ("Fecha:", "estado: 7", "ExecMainStatus=7", "Error de prueba", "5 minutos"):
            self.assertIn(expected, content)
        self.assertEqual(logfile.stat().st_mode & 0o777, 0o600)
        args = (self.root / "notify.args").read_text()
        self.assertIn("--urgency=critical", args)
        self.assertIn("--expire-time=0", args)
        self.assertIn("5 minutos", args)
        self.assertEqual(list(logs.glob(".civica-batch-error.*")), [])

    def test_notification_failure_preserves_log_and_explains_failure(self):
        result = self.run_script("notify_failure.sh", **self.notification_commands(), NOTIFY_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No se pudo mostrar la notificación", result.stderr)
        self.assertTrue((self.root / "logs/civica-batch-error.log").is_file())

    def test_diagnostic_survives_systemctl_and_journal_failures(self):
        result = self.run_script("notify_failure.sh", **self.notification_commands(), DIAGNOSTICS_FAIL="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        content = (self.root / "logs/civica-batch-error.log").read_text()
        self.assertIn("No se pudo consultar el estado", content)
        self.assertIn("No se pudo consultar el journal", content)


class NetworkTests(unittest.TestCase):
    def test_http_exception_is_retried(self):
        response = MagicMock()
        with patch.object(wait_network, "urlopen", side_effect=[HTTPException("respuesta rota"), response]) as request, patch.object(
            wait_network.time, "monotonic", return_value=0
        ), patch.object(wait_network.time, "sleep") as sleep, redirect_stdout(io.StringIO()):
            wait_network.main()
        self.assertEqual(request.call_count, 2)
        sleep.assert_called_once_with(30)

    def test_network_timeout_is_retried(self):
        with patch.object(wait_network, "urlopen", side_effect=[TimeoutError("sin red"), MagicMock()]), patch.object(
            wait_network.time, "monotonic", return_value=0
        ), patch.object(wait_network.time, "sleep") as sleep, redirect_stdout(io.StringIO()):
            wait_network.main()
        sleep.assert_called_once_with(30)

    def test_unavailable_source_fails_after_deadline(self):
        with patch.object(wait_network, "urlopen", side_effect=OSError("sin red")), patch.object(
            wait_network.time, "monotonic", side_effect=[0, 901]
        ), patch.object(wait_network.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "no está disponible"):
                wait_network.main()
        sleep.assert_not_called()


class ServiceConfigTests(unittest.TestCase):
    def config(self, name):
        config = configparser.ConfigParser(interpolation=None)
        config.read(SCRIPTS.parent / "systemd" / name)
        return config

    def test_missing_state_is_not_silently_skipped_and_retries_are_enabled(self):
        config = self.config("civica-batch.service")
        self.assertFalse(any(key.startswith("condition") for key in config["Unit"]))
        self.assertEqual(config["Unit"]["OnFailure"], "civica-batch-error.service")
        self.assertEqual(config["Service"]["Restart"], "on-failure")
        self.assertEqual(config["Service"]["RestartSec"], "5min")
        self.assertEqual(config["Service"]["UMask"], "0077")

    def test_error_service_is_private_and_has_timeout(self):
        config = self.config("civica-batch-error.service")
        self.assertEqual(config["Service"]["UMask"], "0077")
        self.assertEqual(config["Service"]["TimeoutStartSec"], "30s")

    def test_daily_schedule_and_missed_runs_are_preserved(self):
        config = self.config("civica-batch.timer")
        self.assertEqual(config["Timer"]["OnCalendar"], "*-*-* 03:00:00")
        self.assertTrue(config["Timer"].getboolean("Persistent"))


if __name__ == "__main__":
    unittest.main()
