---
name: mysql-query-cli
description: 用 mysqlq 命令行工具安全地查询 MySQL（列数据库、表、表结构、索引、建表语句和表数据）。当需要从命令行了解 MySQL 库结构或读取数据时使用。工具为只读：任何增删改语句都会被拦截并且不会执行。
---

# mysqlq —— MySQL 只读查询 CLI

供 AI agent 在 shell 里探查 MySQL 用的单一二进制工具。它对 SQL 做严格白名单校验，
**只能查询，永远不能修改数据或结构**。需要看库、看表、看字段、看索引、看数据时优先用它。

## 何时使用

- 要确认某个库有哪些表、表里有哪些字段、字段类型/可空/默认值/注释
- 要看索引、主键、唯一约束，或拿完整建表语句（DDL）
- 要读几行数据做样例分析、核对业务含义
- 要判断"某个字段在哪张表里"（`find`）
- 需要稳定的机器可解析输出（`--format json` / `csv`）

不适合：写数据、改结构、跑存储过程、导入导出。工具不提供这些能力，别尝试。

## 安全模型（重要）

三道防线，任何一道都足以拒绝写操作：

1. 词法层：SQL 先在本地被 tokenize，首关键字必须在白名单
   （`SELECT`/`WITH`/`SHOW`/`DESC`/`DESCRIBE`/`EXPLAIN`），且不得出现写关键字
   （`INSERT`/`UPDATE`/`DELETE`/`CREATE`/`ALTER`/`DROP`/`TRUNCATE`/`SET`/`GRANT`…）；
   仅允许单条语句，`/*! ... */` 这类可执行注释会被拒绝。
2. 事务层：查询在 MySQL 的 `READ ONLY` 事务中执行，服务端也会拒绝写入。
3. 连接层：`multiStatements=false`、查询超时、返回行数上限。

被拦截时：**退出码 3，stderr 含 `blocked`，stdout 无数据**。
拦截意味着"这条路走不通"，正确反应是改写成查询语句，**不要**尝试拼接、注释、大小写混淆、
多语句、`INTO OUTFILE` 等方式绕过 —— 那些都会被拦截，而且本来就违反工具约定。

## 位置与构建

```
工具：E:\code\go\mysql-query-cli\bin\mysqlq.exe   （若已在 PATH，直接用 mysqlq）
构建：powershell -NoProfile -ExecutionPolicy Bypass -File E:\code\go\mysql-query-cli\scripts\build.ps1
      （装了 PowerShell 7 时可用 pwsh -NoProfile -File <同一脚本>）
```

调用时建议用绝对路径，避免 cwd 不同导致找不到配置：

```powershell
& 'E:\code\go\mysql-query-cli\bin\mysqlq.exe' tables
```

## 配置

默认自动查找配置文件（第一个存在的生效），无需每次传参：

1. `--config <path>`
2. 环境变量 `MYSQLQ_CONFIG`
3. `./config.yaml`（当前目录）
4. `../config.yaml`
5. 可执行文件同目录的 `config.yaml`

先复制一份本地配置（示例文件在建表仓库里，`config.yaml` 不入库）：

```powershell
Copy-Item E:\code\go\mysql-query-cli\config.example.yaml E:\code\go\mysql-query-cli\config.yaml
```

`config.yaml` 内容（扁平 YAML 子集，注释必须独占一行）：

```yaml
db_host: 127.0.0.1
db_port: 3306
db_name: your_database
db_user: your_user
db_passwd: your_password
max_rows: 20        # 可选：单次返回行数上限，默认 20，硬上限 100
```

可选键：`db_port`（默认 3306）、`db_charset`（默认 utf8mb4）、
`max_rows`（单次返回行数上限，默认 20，硬上限 100——写超过 100 会被钳制成 100 并警告）。
环境变量覆盖：`MYSQLQ_HOST`、`MYSQLQ_PORT`、`MYSQLQ_DB`、`MYSQLQ_USER`、`MYSQLQ_PASSWORD`；
切库更简单的方式是 `--db <name>`。

密码不会出现在任何输出里，不要试图从工具输出里找密码。

## 标准探索流程

先宽后窄，每步只取需要的列，别一上来 `SELECT * FROM 大表`：

```powershell
# 1) 连接正常吗？服务器版本、当前库
& $MQ info
# 2) 有哪些库
& $MQ databases
# 3) 当前库有哪些表（含注释，注释常说明业务含义）
& $MQ tables
# 4) 一次性拿到某张表的列+索引+DDL（推荐，比分别问更省事）
& $MQ schema sale_pay --format json
# 5) 取样例数据（带 LIMIT）
& $MQ query 'SELECT * FROM sale_pay LIMIT 5' --format json
```

需要找字段时用 `find`（无通配符时自动模糊匹配；自己写 `%`/`_` 时按原样传给 LIKE）：

```powershell
& $MQ find order          # 匹配表名、表注释、列名、列注释（等价于 %order%）
& $MQ find '%amount%'     # 显式通配符写法
```

## 命令速查

| 命令 | 作用 | 示例 |
|---|---|---|
| `info` | 连接信息、MySQL 版本、当前库、只读状态、配置来源 | `mysqlq info` |
| `databases` (别名 `dbs`) | 列数据库（默认隐藏系统库） | `mysqlq databases --all` |
| `tables` | 列表/视图：类型、引擎、行数估算、注释 | `mysqlq tables --db bbc` |
| `columns <table>` | 列结构：序号、类型、可空、键、默认值、注释 | `mysqlq columns sale_pay` |
| `indexes <table>` | 索引：唯一性、组成列、类型 | `mysqlq indexes sale_pay` |
| `ddl <table>` | `SHOW CREATE TABLE` 原文 | `mysqlq ddl sale_pay` |
| `schema <table>` | 列+索引+DDL 组合（JSON 为一个对象） | `mysqlq schema sale_pay --format json` |
| `query <sql>` | 执行只读 SQL；`-` 表示从 stdin 读 | `mysqlq query 'SELECT 1'` |
| `find <keyword>` | 按名称/注释模糊搜索表与列（无通配符时自动按 `%关键字%` 匹配） | `mysqlq find order` |
| `version` | 工具版本 | `mysqlq version` |

全局参数（可放在子命令前后）：

| 参数 | 说明 | 默认 |
|---|---|---|
| `-c, --config <path>` | 指定配置文件 | 自动查找 |
| `--db <name>` | 覆盖数据库 | `config.yaml` 的 `db_name` |
| `--format <table\|json\|csv\|md>` | 输出格式 | `table` |
| `--timeout <dur>` | 查询超时（`500ms`/`10s`/`2m`） | `30s` |
| `--max-rows <n>` | 单次最大返回行数，**只允许 1..100** | `20`（config `max_rows` 可调） |
| `--all` | `databases` 时包含系统库 | 关闭 |
| `-h, --help` | 帮助 | |

## 输出与解析

- **stdout 只有数据**；行数、截断提示、警告都在 **stderr**（格式 `[mysqlq] 12 row(s) in 5ms`）。
  agent 解析时读 stdout，必要时用 `2>$null` 屏蔽 stderr。
- 给程序/AI 处理请用 `--format json`：数组，元素为对象，key 是列名。
  - NULL → `null`；数值类型（整数、DECIMAL、FLOAT）→ JSON 数字（DECIMAL 精度保留）；
    日期时间、字符串、二进制 → JSON 字符串（非 UTF-8 二进制为 base64）。
  - `schema` 是唯一例外：JSON 为**对象** `{database, table, columns, indexes, ddl}`。
- `--format csv`：RFC 4180，首行表头，NULL 为空字段；`--format md`：GitHub 表格，便于贴进报告。
  提醒：`columns` 的 CSV 表头首列是 `#`，PowerShell 的 `Import-Csv` 会把它当注释行，解析 CSV 建议用 `--format json`。
- `--format table`（默认）：无边框对齐表格，判断"人看得懂"够用；NULL 显示 `NULL`。
- 结果被截断时 stdout 仍是合法输出，stderr 有 `[mysqlq] truncated to N row(s) (--max-rows)` 提示。

## 返回行数限制（必读）

- **单次查询默认最多返回 20 行**，由 `config.yaml` 的 `max_rows` 决定。
- **绝对硬上限 100 行**：`--max-rows` 只能取 1..100（越界 exit 2）；config 写超过 100 会被钳制为 100 并警告。
- 这不是错误，是防呆设计。要拿更多数据时**不要**反复调大上限（上限不可突破），正确做法：
  1. 用聚合 `COUNT/SUM/AVG/GROUP BY` 直接拿结论；
  2. 用 `LIMIT n OFFSET m` 分页，逐页处理；
  3. 用 `WHERE` 缩小范围（按 id 区间、时间区间、状态）；
  4. 只 `SELECT` 需要的列，减少每页体积。
- 需要长期更大的默认值时，请用户在 `config.yaml` 里设 `max_rows`（≤100），不要自己改配置或绕过工具。

## 退出码与处理策略

| 码 | 含义 | agent 该怎么做 |
|---|---|---|
| 0 | 成功 | 解析 stdout |
| 1 | 运行时错误：连不上库、SQL 报错、表/库不存在、超时、配置缺失 | 读 stderr 修 SQL/表名/参数；连接类错误不要重试超过 2 次 |
| 2 | 用法错误：未知命令、缺参数、非法 flag | 读 stderr 和 `--help` 修正命令行 |
| 3 | 被只读防护拦截 | **不要绕过**。把语句改写成 `SELECT`/`SHOW`/`DESC`/`EXPLAIN`；确实需要写操作就告诉用户"本工具只读，请提供写权限的方式" |

错误信息格式：`mysqlq: <error|usage|blocked|config>: <消息>`。

## 最佳实践

1. **先 schema 后数据**：不确定字段名时先 `schema`/`columns`，避免猜错列名浪费一轮。
2. **查询必须限量**：`LIMIT 20` 起步（工具默认也只放行 20 行）；聚合（`COUNT/SUM/GROUP BY`）拿结论，别把整表读出来；要更多行用分页而不是调大上限。
3. **只取需要的列**：`SELECT id,name` 而不是 `SELECT *`（大表尤其重要，且输出更省 token）。
4. **重查询设超时**：多表 join / 无索引 / 大范围扫描加 `--timeout 10s`，超时后改条件而不是无脑重试。
5. **判断"数据是否存在"**：`SELECT COUNT(*) ... LIMIT 1` 或 `SELECT 1 ... LIMIT 1`。
6. **表结构优先信 `schema --format json`**：一次调用拿全列/索引/DDL，避免多轮往返。
7. **行数估算**：`tables` 输出的 `ROWS` 来自统计信息，可能为 NULL 或不精确；要精确值用 `COUNT(*)`。
8. **信息可能在注释里**：`tables`/`columns` 的 `COMMENT` 常写业务含义，先读注释再猜字段语义。

## PowerShell 引号规则（Windows 必读）

SQL 里有单引号时，外层用双引号；反之用单引号。最稳的做法是外层单引号 + SQL 内部用 `''` 转义：

```powershell
# 正确：外层单引号，SQL 里的字符串用双引号（MySQL 默认允许）
& $MQ query 'SELECT id, pay_status FROM sale_pay WHERE pay_status = "SUCCESS" LIMIT 10'

# 正确：外层双引号（注意变量 $ 会被 PowerShell 展开）
& $MQ query "SELECT COUNT(*) AS c FROM sale_pay"

# 复杂 SQL 用 here-string / 管道，避免转义地狱
$sql = @'
SELECT a.id, b.name
FROM sale_order a JOIN sale_order_detail b ON b.order_id = a.id
LIMIT 10
'@
& $MQ query $sql --format json

# 或者从 stdin 传
Get-Content .\query.sql -Raw | & $MQ query - --format json
```

- SQL 避免多语句；结尾分号可留一个，中间分号会被拦截。
- 表名/列名与保留字冲突时用反引号：`` `order` ``；反引号内的词不参与关键字判断。
- SQL 以 `-` 开头（例如以 `--` 注释开头）时，用 `--` 终止符把它变成位置参数；
  注意 `--` 之后的参数都按位置参数处理，所以 `--format` 之类的 flag 要写在 `--` 前面：

```powershell
& $MQ --format json query -- '-- 说明
SELECT 1 AS ok'
```

- 本机是 Windows PowerShell 5.1：脚本要用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...`，
  没有 `pwsh`；直接调用 exe 不受影响。

## 常见错误排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `config: no config file found ...` | 找不到 config.yaml | `--config` 指定绝对路径，或 `cd` 到项目根目录 |
| `error: cannot connect to MySQL at ...` / `dial tcp ... refused` | MySQL 未启动/端口不对 | 让用户确认服务与 `db_host`/`db_port` |
| `error: access denied for user ...` | 账号密码错/无权限 | 检查 `config.yaml`；不要反复重试 |
| `error: table does not exist: ...` | 表名错/库错 | 先 `tables` 确认，或加 `--db` |
| `blocked: ... forbidden keyword` | 语句含写关键字（`SHOW CREATE TABLE` 也属于此类） | 改成纯查询语句；看建表语句用 `ddl <table>` |
| `blocked: multiple statements` | 有多条语句/中间分号 | 一次只发一条 SQL |
| 输出被截断 | 超过生效行数上限（默认 20，最大 100） | 用聚合或 `LIMIT/OFFSET` 分页；必要时让用户在 config.yaml 调 `max_rows`（≤100） |
| `usage: --max-rows must be between 1 and 100` | 上限不可突破 | 改成 1..100 的值 |
| `error: query timed out after 30s` | 超过 `--timeout` | 优化查询/加索引条件/延长 `--timeout` |

## 完整示例

```powershell
$MQ = 'E:\code\go\mysql-query-cli\bin\mysqlq.exe'

# 探查：库 → 表 → 结构 → 数据
& $MQ databases --format json
& $MQ tables --format json
& $MQ schema sale_pay --format json
& $MQ query 'SELECT id, pay_no, amount, pay_status FROM sale_pay ORDER BY id LIMIT 10' --format json

# 找字段来源
& $MQ find refund --format json

# 统计
& $MQ query 'SELECT pay_status, COUNT(*) AS cnt FROM sale_pay GROUP BY pay_status' --format md
```

## 禁止事项

- 不要尝试执行任何写操作或改结构语句（工具会拦截，且等于在试探安全边界）。
- 不要用 `mysql`/`mysqladmin` 等其他客户端绕过本工具去写库。
- 不要把 `config.yaml` 里的密码回显、写进日志或提交到仓库。
- 不要假设返回类型：JSON 中数值是数字、日期是字符串；需要比较时先确认类型。

## 安装为技能（可选）

把本文件复制到 agent 的技能目录即可被发现：

```powershell
Copy-Item E:\code\go\mysql-query-cli\SKILL.md <skills-dir>\mysql-query-cli\SKILL.md
```

再用 `--config` 或环境变量 `MYSQLQ_CONFIG` 指向数据库配置；若希望直接叫 `mysqlq`，
把 `E:\code\go\mysql-query-cli\bin` 加入 `PATH`。