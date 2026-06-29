# Release Notes

## v0.2.0

Reduces SQLite write pressure caused by `TRACE` interception statistics.

What changed:

- keeps blocking `TRACE` inserts through a SQLite trigger
- switches `trace_block_stats` from per-event counting to low-frequency sampling
- stretches the sampling window from 60 seconds to 1 hour
- updates the repair script to recreate older high-write trigger definitions

Operational result:

- stops the interception counter itself from writing to SQLite hundreds of times per second
- preserves a lightweight signal that `TRACE` spam is still being blocked

## v0.3.0

Moves `TRACE` observation out of SQLite.

What changed:

- switches the SQLite trigger to pure blocking with no in-database counting
- adds an external observer script that records trigger status, `TRACE` leakage checks, `WAL` growth, and normal log volume to `/tmp`

Operational result:

- removes even hourly SQLite writes caused by interception statistics
- keeps observability outside SQLite, where it cannot amplify database write pressure

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
