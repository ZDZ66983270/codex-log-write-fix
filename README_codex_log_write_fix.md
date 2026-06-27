# Codex 日志写盘异常修复补丁

这份说明记录当前对 `~/.codex/logs_2.sqlite` 的保护方案，用来避免 `TRACE` 日志持续高频写盘。

## 当前方案

当前方案分成 3 层：

1. 日志库重定向到 `/tmp`
2. `TRACE` 写入由 SQLite trigger 拦截
3. `launchd` 每 60 秒巡检一次，必要时自动补回 trigger

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
- 顺手执行一次 `PRAGMA wal_checkpoint(PASSIVE);`

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

当前数据库中有一个统计表：

```sql
CREATE TABLE trace_block_stats (
  counter_name TEXT PRIMARY KEY,
  blocked_count INTEGER NOT NULL DEFAULT 0,
  last_blocked_ts INTEGER,
  created_at INTEGER NOT NULL DEFAULT (cast(strftime('%s','now') as integer)),
  updated_at INTEGER NOT NULL DEFAULT (cast(strftime('%s','now') as integer))
);
```

以及一个拦截 `TRACE` 的 trigger：

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

作用：

- 每次遇到 `TRACE` 插入请求时，先更新计数
- 然后忽略这条插入
- 因此 `TRACE` 不会真正写进 `logs` 表

## 常用检查命令

查看当前日志库软链：

```bash
ls -l ~/.codex/logs_2.sqlite ~/.codex/logs_2.sqlite-wal ~/.codex/logs_2.sqlite-shm
```

查看 trigger 是否存在：

```bash
sqlite3 ~/.codex/logs_2.sqlite "select name, sql from sqlite_master where type='trigger';"
```

查看 `TRACE` 拦截计数：

```bash
sqlite3 ~/.codex/logs_2.sqlite "select counter_name, blocked_count, datetime(last_blocked_ts,'unixepoch','localtime') from trace_block_stats;"
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
- `trace_block_stats.blocked_count` 持续增长，说明拦截还在生效
- `WAL` 没有明显膨胀

需要重新关注的信号：

- 最近窗口重新出现大量 `TRACE`
- trigger 消失
- `/tmp/logs_2.sqlite` 被重建后没有及时补 trigger
- WAL 或库文件突然持续快速变大

## 备注

- `blocked_count` 只能统计“启用计数版 trigger 之后”的拦截次数
- 更早历史的 `TRACE` 拦截次数无法精确回溯
- `stderr` 里若看到旧路径报错，可能是早期版本 LaunchAgent 的历史残留，不一定代表当前守护失败
