#!/bin/zsh

set -euo pipefail

DB_LINK="${HOME}/.codex/logs_2.sqlite"
STATE_FILE="/tmp/codex_trace_observer_state.tsv"
SNAPSHOT_FILE="/tmp/codex_trace_observer_latest.tsv"
LOG_FILE="/tmp/codex_trace_observer.log"
WINDOW_SECONDS=900

timestamp() {
  date +"%Y-%m-%d %H:%M:%S"
}

epoch_now() {
  date +%s
}

if [[ ! -e "$DB_LINK" ]]; then
  printf "%s\tskip\tmissing_db_link\n" "$(timestamp)" >> "$LOG_FILE"
  exit 0
fi

DB_PATH="$(python3 - <<'PY'
import os
print(os.path.realpath(os.path.expanduser("~/.codex/logs_2.sqlite")))
PY
)"

if [[ ! -f "$DB_PATH" ]]; then
  printf "%s\tskip\tmissing_db_path\t%s\n" "$(timestamp)" "$DB_PATH" >> "$LOG_FILE"
  exit 0
fi

WAL_PATH="${DB_PATH}-wal"
SHM_PATH="${DB_PATH}-shm"
NOW_TS="$(epoch_now)"
NOW_HUMAN="$(timestamp)"
TRIGGER_PRESENT="$(sqlite3 "$DB_PATH" "SELECT CASE WHEN EXISTS (SELECT 1 FROM sqlite_master WHERE type='trigger' AND name='block_trace_logs') THEN 'yes' ELSE 'no' END;" 2>/dev/null || echo "unknown")"
TRACE_ROWS_LAST_WINDOW="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM logs WHERE level='TRACE' AND ts >= cast(strftime('%s','now') as integer)-${WINDOW_SECONDS};" 2>/dev/null || echo "unknown")"
LEVEL_COUNTS="$(sqlite3 "$DB_PATH" "SELECT group_concat(level || ':' || cnt, ',') FROM (SELECT level, count(*) AS cnt FROM logs WHERE ts >= cast(strftime('%s','now') as integer)-${WINDOW_SECONDS} GROUP BY level ORDER BY level);" 2>/dev/null || echo "unknown")"

if [[ -f "$WAL_PATH" ]]; then
  WAL_SIZE_BYTES="$(stat -f%z "$WAL_PATH" 2>/dev/null || echo 0)"
else
  WAL_SIZE_BYTES=0
fi

if [[ -f "$SHM_PATH" ]]; then
  SHM_SIZE_BYTES="$(stat -f%z "$SHM_PATH" 2>/dev/null || echo 0)"
else
  SHM_SIZE_BYTES=0
fi

PREV_TS=""
PREV_WAL_SIZE=""
if [[ -f "$STATE_FILE" ]]; then
  IFS=$'\t' read -r PREV_TS PREV_WAL_SIZE < "$STATE_FILE" || true
fi

WAL_DELTA_BYTES="na"
ELAPSED_SECONDS="na"
if [[ -n "$PREV_TS" && -n "$PREV_WAL_SIZE" ]]; then
  ELAPSED_SECONDS="$((NOW_TS - PREV_TS))"
  WAL_DELTA_BYTES="$((WAL_SIZE_BYTES - PREV_WAL_SIZE))"
fi

printf "%s\t%s\n" "$NOW_TS" "$WAL_SIZE_BYTES" > "$STATE_FILE"
printf "%s\ttrigger_present=%s\ttrace_rows_last_%ss=%s\twal_bytes=%s\twal_delta_bytes=%s\telapsed_seconds=%s\tshm_bytes=%s\tlevels=%s\n" \
  "$NOW_HUMAN" \
  "$TRIGGER_PRESENT" \
  "$WINDOW_SECONDS" \
  "$TRACE_ROWS_LAST_WINDOW" \
  "$WAL_SIZE_BYTES" \
  "$WAL_DELTA_BYTES" \
  "$ELAPSED_SECONDS" \
  "$SHM_SIZE_BYTES" \
  "$LEVEL_COUNTS" > "$SNAPSHOT_FILE"

cat "$SNAPSHOT_FILE" >> "$LOG_FILE"
