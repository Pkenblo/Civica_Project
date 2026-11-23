#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$ROOT/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo 'Falta el entorno virtual del proyecto. Desde la raíz, ejecuta: python3 -m venv .venv' >&2
    exit 1
fi

if ! "$PYTHON" -c 'import snowflake.connector'; then
    echo 'Para instalar el conector, ejecuta desde la raíz: .venv/bin/python -m pip install -r visualizacion/requirements.txt' >&2
    exit 1
fi

exec "$PYTHON" "$ROOT/visualizacion/panel.py" "$@"
