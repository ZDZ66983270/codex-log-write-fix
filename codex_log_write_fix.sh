#!/bin/zsh

set -euo pipefail

DB_LINK="${HOME}/.codex/logs_2.sqlite"
LOG_FILE="${HOME}/Library/Logs/com.user.codex-log-write-fix.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OBSERVER_SCRIPT="${SCRIPT_DIR}/codex_trace_observer.sh"

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

read -r -d '' TRIGGER_SQL <<'SQL' || true
CREATE TRIGGER block_trace_logs
BEFORE INSERT ON logs
WHEN NEW.level = 'TRACE'
BEGIN
  SELECT RAISE(IGNORE);
END;
SQL

current_trigger_sql="$(sqlite3 "$DB_PATH" "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='block_trace_logs';" 2>/dev/null || true)"
normalized_trigger_sql="$(printf '%s' "$current_trigger_sql" | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
trigger_is_valid=0

if [[ -n "$normalized_trigger_sql" ]]; then
  if [[ "$normalized_trigger_sql" == *"CREATE TRIGGER block_trace_logs"* ]] \
    && [[ "$normalized_trigger_sql" == *"BEFORE INSERT ON logs"* ]] \
    && [[ "$normalized_trigger_sql" == *"WHEN NEW.level = 'TRACE'"* ]] \
    && [[ "$normalized_trigger_sql" == *"SELECT RAISE(IGNORE)"* ]]; then
    trigger_is_valid=1
  fi
fi

if [[ "$trigger_is_valid" -ne 1 ]]; then
  sqlite3 "$DB_PATH" "DROP TRIGGER IF EXISTS block_trace_logs;"
  sqlite3 "$DB_PATH" "$TRIGGER_SQL"
  log_msg "installed pure-block TRACE trigger on ${DB_PATH}"
fi

sqlite3 "$DB_PATH" "PRAGMA wal_checkpoint(PASSIVE);" >/dev/null 2>&1 || true

if [[ -f "$OBSERVER_SCRIPT" ]]; then
  /bin/zsh "$OBSERVER_SCRIPT" >/dev/null 2>&1 || true
fi
