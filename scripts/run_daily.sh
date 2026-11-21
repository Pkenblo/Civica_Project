#!/usr/bin/bash
set -euo pipefail
umask 0077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$ROOT/.venv/bin/python"
export PYTHONUNBUFFERED=1

log() {
    echo "[$(date --iso-8601=seconds)] $*"
}

# Un único proceso diario, también para ejecuciones manuales.
mkdir -p "$ROOT/scripts/state"
exec 9>> "$ROOT/scripts/state/daily.lock"
if flock --exclusive --nonblock --conflict-exit-code 75 9; then
    :
else
    status=$?
    if (( status == 75 )); then
        log "Ya hay una ejecución diaria en curso. No se iniciará otra."
        exit 0
    fi
    log "No se pudo adquirir el bloqueo diario (código $status)." >&2
    exit "$status"
fi

# La base se crea una sola vez, de forma explícita, nunca en la tarea diaria.
"$PYTHON" - "$ROOT" <<'PY'
import json
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

root = Path(sys.argv[1])
for name, columns in (("crimes", 20), ("arrests", 34)):
    path = root / "scripts" / "state" / name / "state.sqlite"
    if not path.is_file():
        raise SystemExit(
            f"Falta {path}. Recupera el estado o registra explícitamente una "
            "base con --inicial-web antes de automatizar."
        )
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)) as db:
        header = db.execute("SELECT value FROM meta WHERE key = 'header'").fetchone()
        if not header or len(json.loads(header[0])) != columns:
            raise SystemExit(f"Estado sin inicializar o incompatible: {path}")
PY

"$PYTHON" "$ROOT/scripts/wait_network.py"

log "Preparando crimes y arrests en paralelo."
pids=()
cleanup() {
    for pid in "${pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"$PYTHON" "$ROOT/scripts/batch_crimes.py" --preparar &
pids+=("$!")
"$PYTHON" "$ROOT/scripts/batch_arrests.py" --preparar &
pids+=("$!")

status=0
for pid in "${pids[@]}"; do
    wait "$pid" || status=1
done
pids=()
if (( status != 0 )); then
    log "Ha fallado la preparación. No se subirá ningún lote."
    exit 1
fi

log "Preparación completada. Subiendo crimes al stage."
"$PYTHON" "$ROOT/scripts/batch_crimes.py"
log "Subiendo arrests al stage."
"$PYTHON" "$ROOT/scripts/batch_arrests.py"
log "Ejecución diaria completada."
