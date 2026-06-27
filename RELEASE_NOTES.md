# Release Notes

## v0.1.0

Initial release of the Codex log write fix patch.

Included components:

- `codex_log_write_fix.sh`
- `com.user.codex-log-write-fix.plist`
- `README_codex_log_write_fix.md`

What it does:

- redirects the Codex `logs_2.sqlite` database to `/tmp`
- blocks `TRACE` inserts through a SQLite trigger
- counts blocked `TRACE` write attempts
- uses a `launchd` job to restore protection if the trigger disappears

Operational result:

- prevents `TRACE` log spam from continuously writing into the persistent Codex directory
- preserves visibility into normal `DEBUG` / `INFO` / `WARN` / `ERROR` activity
