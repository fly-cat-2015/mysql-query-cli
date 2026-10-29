---
name: mysql-query-cli
description: 用 mysqlq 命令行工具安全地查询 MySQL（列数据库、表、表结构、索引、建表语句和表数据）。当需要从命令行了解 MySQL 库结构或读取数据时使用。工具为只读：任何增删改语句都会被拦截并且不会执行。
---

# mysqlq —— MySQL 只读查询 CLI

`mysqlq` 是给 AI agent（也给人）用的单一二进制命令行工具，用于在 shell 里探查 MySQL：
数据库、表、表结构、索引、建表语句、表数据。它对 SQL 做严格白名单校验，**只能查，不能改**。

## 何时使用

- 确认某个库有哪些表、某张表有哪些字段、字段类型/可空/默认值/注释
- 查看索引、主键、唯一约束，或取完整建表语句（DDL）
- 读少量数据做样例分析、核对业务含义
- 判断"某个字段在哪张表里"（`find`）
- 需要机器可解析的稳定输出（`--format json` 或 `csv`）

不适用：写数据、改结构、跑存储过程、导入导出。工具不提供这些能力，不要尝试。

## 安全模型（必读）

三道防线，任意一道都足以拒绝写操作：

1. **词法层**：SQL 先在本地被逐 token 审核，首关键字必须在白名单
   （`SELECT` / `WITH` / `SHOW` / `DESC` / `DESCRIBE` / `EXPLAIN`），且不得出现写关键字
   （`INSERT` / `UPDATE` / `DELETE` / `CREATE` / `ALTER` / `DROP` / `TRUNCATE` / `SET` / `GRANT` …）；
   只允许单条语句；`/*! ... */` 这类可执行注释会被拒绝。
2. **事务层**：查询在 MySQL 的 `READ ONLY` 事务中执行，服务端同样会拒绝写入。
3. **连接层**：禁用多语句、查询超时、返回行数上限。

被拦截时：**退出码 3、stderr 含 `blocked`、stdout 无数据**。
拦截意味着这条路走不通，正确反应是改写成查询语句，**不要**尝试拼接、注释、大小写混淆、
多语句、`INTO OUTFILE` 等方式绕过 —— 都会被拦截，而且本来就违反工具约定。

## 找到可执行文件与配置

- 本 `SKILL.md` 通常与 `mysqlq`（Windows 上为 `mysqlq.exe`）和 `config.yaml` 放在**同一个目录**。
- 若 `mysqlq` 已在 `PATH` 中，直接调用 `mysqlq` 即可；否则用绝对路径或先 `cd` 到该目录。

```bash
# macOS / Linux
./mysqlq info
```

```powershell
# Windows PowerShell
.\mysqlq.exe info
```

配置**默认读取可执行文件同目录的 `config.yaml`**，与当前工作目录无关；
需要指向别处时用 `--config <path>` 或环境变量 `MYSQLQ_CONFIG`（见下节）。

## 配置

查找顺序（第一个存在的生效）：

1. `--config <path>`
2. 环境变量 `MYSQLQ_CONFIG`
3. **可执行文件所在目录的 `config.yaml`**（默认）
4. `./config.yaml`（当前工作目录，兜底）

配置文件是扁平 YAML 子集：只支持 `key: value`，**注释必须独占一行**，不要写在值后面。

```yaml
db_host: 127.0.0.1
db_port: 3306
db_name: your_database
db_user: your_user
db_passwd: your_password
max_rows: 20
```

可选键：`db_port`（默认 3306）、`db_charset`（默认 utf8mb4）、
`max_rows`（单次返回行数上限，默认 20，硬上限 100）。
环境变量覆盖：`MYSQLQ_HOST` / `MYSQLQ_PORT` / `MYSQLQ_DB` / `MYSQLQ_USER` / `MYSQLQ_PASSWORD`；
临时切库更简单的方式是 `--db <name>`。

密码不会出现在任何输出里，不要试图从工具输出里找密码。

## 标准探索流程

先宽后窄，每步只取需要的列，不要一上来 `SELECT * FROM 大表`：

```bash
./mysqlq info                                               # 连通性、MySQL 版本、当前库
./mysqlq databases                                          # 有哪些库
./mysqlq tables                                             # 当前库的表（含注释、行数估算）
./mysqlq schema sale_pay --format json                      # 一次拿全列 + 索引 + DDL
./mysqlq query 'SELECT * FROM sale_pay LIMIT 5' --format json
```

找不到字段在哪张表时用 `find`（无通配符时自动按 `%关键字%` 模糊匹配；显式写 `%`/`_` 时按原样传给 LIKE）：

```bash
./mysqlq find order
./mysqlq find '%amount%'
```

## 命令速查

| 命令 | 作用 | 示例 |
|---|---|---|
| `info` | 连接信息、MySQL 版本、当前库、只读状态、配置来源 | `mysqlq info` |
| `databases`（别名 `dbs`） | 数据库列表 | `mysqlq databases --all` |
| `tables` | 表/视图：类型、引擎、行数估算、注释 | `mysqlq tables` |
| `columns <table>` | 列结构：序号、类型、可空、键、默认值、注释 | `mysqlq columns sale_pay` |
| `indexes <table>` | 索引：唯一性、组成列、类型 | `mysqlq indexes sale_pay` |
| `ddl <table>` | `SHOW CREATE TABLE` 原文 | `mysqlq ddl sale_pay` |
| `schema <table>` | 列 + 索引 + DDL 组合（JSON 为一个对象） | `mysqlq schema sale_pay --format json` |
| `query <sql>` | 执行一条只读 SQL；`-` 表示从 stdin 读 | `mysqlq query 'SELECT 1'` |
| `find <keyword>` | 按名称/注释模糊搜索表与列 | `mysqlq find order` |
| `version` | 工具版本 | `mysqlq version` |

全局参数（可放在子命令前后）：

| 参数 | 说明 | 默认 |
|---|---|---|
| `-c, --config <path>` | 指定配置文件 | 可执行文件同目录的 `config.yaml` |
| `--db <name>` | 覆盖数据库名 | 配置文件里的 `db_name` |
| `--format <table\|json\|csv\|md>` | 输出格式 | `table` |
| `--timeout <dur>` | 查询超时，如 `500ms` / `10s` / `2m` | `30s` |
| `--max-rows <n>` | 单次最大返回行数，**只允许 1..100** | `20`（配置 `max_rows` 可调） |
| `--all` | `databases` 时包含系统库 | 关闭 |
| `-h, --help` | 帮助 | |

## 输出格式与解析

- **stdout 只放数据**；行数统计、截断提示、警告都写 **stderr**（如 `[mysqlq] 12 row(s) in 5ms`）。
  agent 解析时读 stdout，必要时丢弃 stderr（`2>/dev/null`；Windows 用 `2>$null`）。
- 给程序/AI 处理首选 `--format json`：数组，元素为对象，key 是列名。
  - NULL → `null`；数值类型（整数、DECIMAL、FLOAT）→ JSON 数字（DECIMAL 精度保留）；
    日期时间、字符串 → JSON 字符串；非 UTF-8 二进制 → base64 字符串。
  - `schema` 是唯一例外：JSON 为**对象** `{database, table, columns, indexes, ddl}`。
- `--format csv`：RFC 4180，首行表头，NULL 为空字段。
- `--format md`：GitHub 风格表格，便于贴进报告。
- `--format table`（默认）：无边框对齐表格，人读友好，NULL 显示为 `NULL`。
- 结果被截断时 stdout 仍是合法输出，stderr 提示 `[mysqlq] truncated to N row(s) (--max-rows)`。
- 小坑：`columns` 的 CSV 表头首列是 `#`，部分 CSV 解析器（如 PowerShell `Import-Csv`）会把它当注释；
  解析 CSV 优先用 `--format json`。

## 返回行数限制（必读）

- **单次查询默认最多返回 20 行**，由配置文件的 `max_rows` 决定。
- **绝对硬上限 100 行**：`--max-rows` 只能取 1..100（越界 exit 2）；配置写超过 100 会被钳制为 100 并警告。
- 这是防呆设计，不是错误。要拿更多数据时**不要**反复调大上限（突破不了），正确做法：
  1. 用聚合 `COUNT/SUM/AVG/GROUP BY` 直接拿结论；
  2. 用 `LIMIT n OFFSET m` 分页，逐页处理；
  3. 用 `WHERE` 缩小范围（id 区间、时间区间、状态）；
  4. 只 `SELECT` 需要的列，减小每页体积。
- 需要长期更大的默认值时，请用户在配置里设 `max_rows`（≤100），不要自己改配置或绕过工具。

## 退出码与处理策略

| 码 | 含义 | agent 该怎么做 |
|---|---|---|
| 0 | 成功 | 解析 stdout |
| 1 | 运行时错误：连不上库、SQL 报错、表/库不存在、超时、配置缺失 | 读 stderr 修 SQL/表名/参数；连接类错误不要重试超过 2 次 |
| 2 | 用法错误：未知命令、缺参数、非法 flag | 读 stderr 和 `--help` 修正命令行 |
| 3 | 被只读防护拦截 | **不要绕过**。把语句改写成 `SELECT`/`SHOW`/`DESC`/`EXPLAIN`；确需写操作就告诉用户"本工具只读" |

错误信息格式：`mysqlq: <error|usage|blocked|config>: <消息>`。

## 最佳实践

1. **先结构后数据**：不确定字段名时先 `schema` / `columns`，避免猜错列名浪费一轮。
2. **查询必须限量**：`LIMIT 20` 起步；聚合出结论，别把整表读出来；要更多行用分页。
3. **只取需要的列**：`SELECT id, name` 而不是 `SELECT *`。
4. **重查询设超时**：多表 join / 无索引 / 大范围扫描加 `--timeout 10s`；超时后改条件而不是无脑重试。
5. **判断"数据是否存在"**：`SELECT 1 ... LIMIT 1` 或 `COUNT(*)`。
6. **表结构优先信 `schema --format json`**：一次调用拿全列/索引/DDL，减少往返。
7. **`tables` 的 `ROWS` 是统计估算**，可能为 NULL 或不精确；要精确值用 `COUNT(*)`。
8. **注释常含业务含义**：`tables` / `columns` 的 `COMMENT` 先读，再猜字段语义。

## 跨平台调用注意

工具本身跨平台（macOS / Linux 为 `mysqlq`，Windows 为 `mysqlq.exe`），只有 shell 语法不同：

| 场景 | macOS / Linux | Windows PowerShell |
|---|---|---|
| 调用 | `./mysqlq info` | `.\mysqlq.exe info` |
| 引用带空格路径 | `"/opt/mysqlq/bin/mysqlq" info` | `& "C:\mysqlq\mysqlq.exe" info` |
| 丢弃 stderr | `2>/dev/null` | `2>$null` |

SQL 的引号规则（跨平台通用做法是用 stdin 传，避开 shell 转义）：

```bash
# 单引号包裹 SQL（SQL 内部字符串用双引号，MySQL 默认可接受）
./mysqlq query 'SELECT id FROM sale_pay WHERE pay_status = "SUCCESS" LIMIT 10'

# 复杂 SQL 用 heredoc，最稳
./mysqlq query - --format json <<'SQL'
SELECT a.id, b.name
FROM sale_order a JOIN sale_order_detail b ON b.order_id = a.id
LIMIT 10
SQL
```

```powershell
# Windows PowerShell：here-string + stdin
$sql = @'
SELECT a.id, b.name FROM sale_order a JOIN sale_order_detail b ON b.order_id = a.id LIMIT 10
'@
$sql | .\mysqlq.exe query - --format json
```

- 一条命令只发一条 SQL；结尾可留一个分号，中间分号会被拦截。
- 表名/列名与保留字冲突时用反引号：`` `order` ``（反引号内不参与关键字判断）。
- SQL 作为**参数**且以 `-` 开头时（例如以 `--` 注释开头），要用 `--` 终止符，
  且 `--` 之后一律按位置参数处理 —— 所以 `--format` 等 flag 必须写在 `--` 之前。
  更省心的做法是走 stdin（`query -` + heredoc），完全不涉及参数解析：

```bash
# 推荐：stdin 传入，SQL 首行是注释也没问题
./mysqlq --format json query - <<'SQL'
-- 说明：查一条
SELECT 1 AS ok
SQL

# 参数形式需要 -- 终止符
./mysqlq --format json query -- '-- note
SELECT 1 AS ok'
```

## 常见错误排查

| 现象 | 原因 | 处理 |
|---|---|---|
| `config: no config file found ...` | 工具目录没有 `config.yaml` | 把配置放到 `mysqlq` 同目录，或用 `--config <路径>` |
| `error: cannot connect to MySQL at ...` | MySQL 未启动 / 端口不对 | 确认服务与 `db_host`/`db_port` |
| `error: access denied for user ...` | 账号密码错 / 无权限 | 检查配置；不要反复重试 |
| `error: table does not exist: ...` | 表名错 / 库错 | 先 `tables` 确认，或加 `--db` |
| `blocked: ... forbidden keyword` | 语句含写关键字（`SHOW CREATE TABLE` 也算） | 改成纯查询；看 DDL 用 `ddl <table>` |
| `blocked: multiple statements` | 多条语句 / 中间分号 | 一次只发一条 SQL |
| 输出被截断 | 超过生效行数上限（默认 20，最大 100） | 用聚合或 `LIMIT/OFFSET` 分页 |
| `usage: --max-rows must be between 1 and 100` | 上限不可突破 | 改成 1..100 |
| `error: query timed out after 30s` | 超过 `--timeout` | 优化查询 / 加索引条件 / 延长 `--timeout` |

## 完整示例

```bash
MQ=./mysqlq     # 或 PATH 中的 mysqlq（Windows：.\mysqlq.exe）

# 探查：库 → 表 → 结构 → 数据
$MQ databases --format json
$MQ tables --format json
$MQ schema sale_pay --format json
$MQ query 'SELECT id, pay_no, amount, pay_status FROM sale_pay ORDER BY id LIMIT 10' --format json

# 找字段来源
$MQ find refund --format json

# 统计
$MQ query 'SELECT pay_status, COUNT(*) AS cnt FROM sale_pay GROUP BY pay_status' --format md
```

## 禁止事项

- 不要尝试执行任何写操作或改结构语句（会被拦截，且等于在试探安全边界）。
- 不要用 `mysql` / `mysqladmin` 等其它客户端绕过本工具去写库。
- 不要把配置里的密码回显、写进日志或提交到仓库。
- 不要假设返回类型：JSON 中数值是数字、日期是字符串；比较前先确认类型。