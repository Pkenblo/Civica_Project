#!/usr/bin/bash
set -euo pipefail
umask 0077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/logs"
LOGFILE="$ROOT/logs/civica-batch-error.log"
temporary="$(mktemp "$ROOT/logs/.civica-batch-error.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT

{
    printf 'Fecha: %s\nUnidad: civica-batch.service\n' "$(date --iso-8601=seconds)"
    printf 'Reintento automático configurado: cada 5 minutos.\n'
    printf 'Resultado notificado: %s; código: %s; estado: %s\n\n' \
        "${MONITOR_SERVICE_RESULT:-no disponible}" \
        "${MONITOR_EXIT_CODE:-no disponible}" \
        "${MONITOR_EXIT_STATUS:-no disponible}"
    systemctl --user show civica-batch.service \
        --property=Result --property=ExecMainCode --property=ExecMainStatus \
        --property=NRestarts || printf 'No se pudo consultar el estado del servicio.\n'
    printf '\nÚltimas 100 líneas del registro:\n'
    journalctl --user -u civica-batch.service -n 100 --no-pager \
        || printf 'No se pudo consultar el journal.\n'
} > "$temporary" 2>&1
mv -- "$temporary" "$LOGFILE"

if ! notify-send --urgency=critical --expire-time=0 \
    "Civica: ha fallado la carga diaria" \
    "Se reintentará cada 5 minutos. Consulta $LOGFILE"; then
    echo "No se pudo mostrar la notificación. El diagnóstico está en $LOGFILE." >&2
fi
