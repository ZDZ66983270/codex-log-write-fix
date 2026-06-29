# Codex 日志写盘异常修复补丁

这份说明记录当前对 `~/.codex/logs_2.sqlite` 的保护方案，用来避免 `TRACE` 日志持续高频写盘。

## 当前方案

当前方案分成 4 层：

1. 日志库重定向到 `/tmp`
2. `TRACE` 写入由 SQLite trigger 拦截
3. `launchd` 每 60 秒巡检一次，必要时自动补回 trigger
4. 外部观测脚本把侧面指标写到 `/tmp`，不在 SQLite 里做高频计数

## 日志库路径

当前 `~/.codex` 下的 3 个路径都是软链：

- `~/.codex/logs_2.sqlite -> /tmp/logs_2.sqlite`
- `~/.codex/logs_2.sqlite-wal -> /tmp/logs_2.sqlite-wal`
- `~/.codex/logs_2.sqlite-shm -> /tmp/logs_2.sqlite-shm`

这表示实时日志写入会落到 `/tmp`，而不是直接持续写 `~/.codex`。

## 自愈脚本

工作区脚本：

- [codex_log_write_fix.sh](/Users/zhangzy/Documents/Codex/codex_log_write_fix.sh)

LaunchAgent 实际执行的脚本副本：

- `/Users/zhangzy/Library/Application Support/Codex/codex_log_write_fix.sh`

作用：

- 找到 `~/.codex/logs_2.sqlite` 当前实际指向的数据库
- 检查 `block_trace_logs` trigger 是否存在
- 如果 trigger 丢失，则自动补回
- trigger 使用“纯拦截”模式，不再更新 SQLite 统计表
- 顺手执行一次 `PRAGMA wal_checkpoint(PASSIVE);`

外部观测脚本：

- [codex_trace_observer.sh](/Users/zhangzy/My%20Docs/Privates/22-Vibe%20Coding/Codex-log-write-fix/codex_trace_observer.sh)

作用：

- 把 trigger 是否存在、最近窗口里是否出现落库 `TRACE`、`WAL` 大小和变化量、普通日志级别分布写到 `/tmp`
- 这些信息写在 SQLite 外部，避免为了统计 `TRACE` 再回到高频写库

## LaunchAgent

工作区配置文件：

- [com.user.codex-log-write-fix.plist](/Users/zhangzy/Documents/Codex/com.user.codex-log-write-fix.plist)

已安装位置：

- `~/Library/LaunchAgents/com.user.codex-log-write-fix.plist`

行为：

- 登录时运行一次
- 之后每 60 秒运行一次

标签名：

- `com.user.codex-log-write-fix`

## SQLite 保护逻辑

旧版本里曾使用 `trace_block_stats` 表做统计，但这会让“统计本身”也跟着写库：

```sql
CREATE TABLE trace_block_stats (
  counter_name TEXT PRIMARY KEY,
  blocked_count INTEGER NOT NULL DEFAULT 0,
  last_blocked_ts INTEGER,
  created_at INTEGER NOT NULL DEFAULT (cast(strftime('%s','now') as integer)),
  updated_at INTEGER NOT NULL DEFAULT (cast(strftime('%s','now') as integer))
);
```

旧版 trigger：

```sql
CREATE TRIGGER block_trace_logs
BEFORE INSERT ON logs
WHEN NEW.level = 'TRACE'
BEGIN
  INSERT INTO trace_block_stats (
    counter_name,
    blocked_count,
    last_blocked_ts,
    created_at,
    updated_at
  )
  VALUES (
    'trace',
    1,
    cast(strftime('%s','now') as integer),
    cast(strftime('%s','now') as integer),
    cast(strftime('%s','now') as integer)
  )
  ON CONFLICT(counter_name) DO UPDATE SET
    blocked_count = blocked_count + 1,
    last_blocked_ts = cast(strftime('%s','now') as integer),
    updated_at = cast(strftime('%s','now') as integer);

  SELECT RAISE(IGNORE);
END;
```

旧版作用：

- 每次遇到 `TRACE` 插入请求时，先更新计数
- 然后忽略这条插入
- 因此 `TRACE` 不会真正写进 `logs` 表

后来虽然降成过低频采样版，但它本质上仍然会周期性写 SQLite。当前推荐是纯拦截版 trigger：

```sql
CREATE TRIGGER block_trace_logs
BEFORE INSERT ON logs
WHEN NEW.level = 'TRACE'
BEGIN
  SELECT RAISE(IGNORE);
END;
```

纯拦截版作用：

- 每条 `TRACE` 仍然会被拦截
- SQLite 内部不再为了 `TRACE` 统计去更新任何计数
- `TRACE` 观测改由外部脚本完成
- 这样可以把 `TRACE` 的附加写盘压到接近零

## 常用检查命令

查看当前日志库软链：

```bash
ls -l ~/.codex/logs_2.sqlite ~/.codex/logs_2.sqlite-wal ~/.codex/logs_2.sqlite-shm
```

查看 trigger 是否存在：

```bash
sqlite3 ~/.codex/logs_2.sqlite "select name, sql from sqlite_master where type='trigger';"
```

查看当前 trigger 具体定义：

```bash
sqlite3 ~/.codex/logs_2.sqlite "select sql from sqlite_master where type='trigger' and name='block_trace_logs';"
```

运行一次外部观测：

```bash
/bin/zsh ./codex_trace_observer.sh
```

查看最新外部观测快照：

```bash
cat /tmp/codex_trace_observer_latest.tsv
```

查看外部观测历史：

```bash
tail -n 20 /tmp/codex_trace_observer.log
```

查看最近 15 分钟日志级别分布：

```bash
sqlite3 ~/.codex/logs_2.sqlite "select level, count(*) as cnt from logs where ts >= cast(strftime('%s','now') as integer)-900 group by level order by cnt desc;"
```

查看 LaunchAgent 状态：

```bash
launchctl print gui/$(id -u)/com.user.codex-log-write-fix
```

## 当前判断标准

可以认为问题已经被控制住的信号：

- 最近窗口里没有 `TRACE`
- `block_trace_logs` trigger 存在
- 外部观测里 `trace_rows_last_900s=0`
- `WAL` 没有明显膨胀

需要重新关注的信号：

- 最近窗口重新出现大量 `TRACE`
- trigger 消失
- `/tmp/logs_2.sqlite` 被重建后没有及时补 trigger
- WAL 或库文件突然持续快速变大

## 备注

- 在“不改 Codex 本体”的前提下，外部无法精确拿到每一条被 trigger `RAISE(IGNORE)` 的 `TRACE`
- 外部观测能提供的是侧面证据：trigger 是否存在、最近窗口里是否有漏进 `logs` 的 `TRACE`、`WAL` 是否异常膨胀、普通日志量是否异常
- `stderr` 里若看到旧路径报错，可能是早期版本 LaunchAgent 的历史残留，不一定代表当前守护失败
