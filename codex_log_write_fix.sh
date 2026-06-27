#!/bin/zsh

set -euo pipefail

DB_LINK="${HOME}/.codex/logs_2.sqlite"
LOG_FILE="${HOME}/Library/Logs/com.user.codex-log-write-fix.log"

mkdir -p "$(dirname "$LOG_FILE")"

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

log_msg() {
  printf "%s %s\n" "$(timestamp)" "$1" >> "$LOG_FILE"
}

if [[ ! -e "$DB_LINK" ]]; then
  log_msg "skip: ${DB_LINK} does not exist"
  exit 0
fi

DB_PATH="$(python3 - <<'PY'
import os
print(os.path.realpath(os.path.expanduser("~/.codex/logs_2.sqlite")))
PY
)"

if [[ ! -f "$DB_PATH" ]]; then
  log_msg "skip: resolved db path missing: ${DB_PATH}"
  exit 0
fi

TRIGGER_SQL="CREATE TRIGGER IF NOT EXISTS block_trace_logs BEFORE INSERT ON logs WHEN NEW.level = 'TRACE' BEGIN SELECT RAISE(IGNORE); END;"
CHECK_SQL="SELECT name FROM sqlite_master WHERE type='trigger' AND name='block_trace_logs';"

current_trigger="$(sqlite3 "$DB_PATH" "$CHECK_SQL" 2>/dev/null || true)"
if [[ "$current_trigger" != "block_trace_logs" ]]; then
  sqlite3 "$DB_PATH" "$TRIGGER_SQL"
  log_msg "installed TRACE trigger on ${DB_PATH}"
fi

sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true
