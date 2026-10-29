# mysqlq — MySQL 只读查询 CLI

一个给 AI agent（也给人）用的 MySQL 查询命令行工具：查看数据库、表、表结构、索引、建表语句和表数据。
**只读**——任何增删改语句都会在发往数据库之前被拦截，绝不执行。

- 单一静态二进制，除 MySQL 驱动外零第三方依赖
- 四种输出格式：`table`（默认，人读）/ `json`（agent 解析）/ `csv` / `md`
- 三道只读防线：本地 SQL 词法拦截 → 服务端 `READ ONLY` 事务 → 单语句 + 超时 + 行数上限

规格详见 [docs/SPEC.md](docs/SPEC.md)，AI 使用说明见 [SKILL.md](SKILL.md)，验证报告见 [docs/VERIFICATION.md](docs/VERIFICATION.md)。

## 部署布局

`mysqlq.exe`、`config.yaml`、`SKILL.md` 放在**同一个目录**即可整体复制使用：

```
mysql-query-cli\
  mysqlq.exe          # 构建产物
  config.yaml         # 本地配置（默认被读取；不入库）
  SKILL.md            # AI 使用说明
  config.example.yaml # 配置示例（入库）
```

工具默认读取**可执行文件所在目录**的 `config.yaml`，与当前工作目录无关；
需要改路径时用 `--config <path>` 或环境变量 `MYSQLQ_CONFIG`。

## 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
# 产物：.\mysqlq.exe（仓库根目录，与 config.yaml、SKILL.md 同级）
```

> 若安装了 PowerShell 7，`pwsh -NoProfile -File .\scripts\build.ps1` 亦可。

> `scripts\env.ps1` 会把 GOCACHE / GOMODCACHE 放到工作区 `.cache` 并设置 `GOSUMDB=off`
> （本机沙箱无法写用户级缓存）。正常联网环境下直接 `go build -o mysqlq.exe .` 也可以。
> 唯一依赖：`github.com/go-sql-driver/mysql`。

## 配置

先复制示例配置为本地配置（`config.yaml` 已被 `.gitignore` 排除，不会提交到仓库）：

```powershell
Copy-Item config.example.yaml config.yaml
```

配置文件为扁平 YAML 子集（`key: value`，注释独占一行），查找顺序（第一个存在的生效）：
`--config` → `MYSQLQ_CONFIG` → **`mysqlq.exe` 同目录的 `config.yaml`（默认）** → `./config.yaml`（兜底，便于 `go run`）。

```yaml
db_host: 127.0.0.1
db_port: 3306
db_name: your_database
db_user: your_user
db_passwd: your_password
max_rows: 20
```

可选：`db_port`（默认 3306）、`db_charset`（默认 utf8mb4）、`max_rows`（单次返回行数上限，默认 20，硬上限 100）。
环境变量可覆盖：`MYSQLQ_HOST` / `MYSQLQ_PORT` / `MYSQLQ_DB` / `MYSQLQ_USER` / `MYSQLQ_PASSWORD`。

## 快速开始

```powershell
$MQ = '.\mysqlq.exe'

& $MQ info                                # 连接信息、MySQL 版本、当前库
& $MQ databases                           # 有哪些库
& $MQ tables                              # 当前库的表（含注释、行数估算）
& $MQ schema sale_pay --format json       # 列 + 索引 + DDL，一次拿全
& $MQ query 'SELECT * FROM sale_pay LIMIT 5' --format json
& $MQ find order                          # 按表名/列名/注释搜索
```

## 命令

| 命令 | 说明 |
|---|---|
| `info` | 连接信息、服务器版本、当前库、只读状态、配置来源 |
| `databases` / `dbs` | 数据库列表（`--all` 含系统库） |
| `tables` | 表/视图列表：类型、引擎、行数估算、注释 |
| `columns <table>` | 列结构：类型、可空、键、默认值、注释 |
| `indexes <table>` | 索引：唯一性、组成列、类型 |
| `ddl <table>` | `SHOW CREATE TABLE` 原文 |
| `schema <table>` | 列 + 索引 + DDL 组合视图 |
| `query <sql>` | 执行只读 SQL（`-` 表示从 stdin 读取） |
| `find <keyword>` | 按名称/注释模糊搜索表和列 |
| `version` | 工具版本 |

全局参数：`-c/--config`、`--db`、`--format table|json|csv|md`、`--timeout`（默认 `30s`）、`--max-rows`（默认 `20`，仅允许 `1..100`）。

### 返回行数限制

单次查询默认最多返回 **20 行**；在 `config.yaml` 里写 `max_rows: 50` 可以调整；**任何情况下不超过 100 行**。
优先级：`--max-rows` > `config.yaml` 的 `max_rows` > 默认 20。超出上限时停止读取，stdout 仍是合法输出，
stderr 提示 `truncated`。`--max-rows` 越界（<1 或 >100）属于用法错误，退出码 2；配置里写超过 100 会钳制为 100 并警告。

## 只读是怎么保证的

1. **词法拦截（连库之前）**：自研 tokenizer 正确跳过字符串、反引号标识符和注释，
   首关键字必须属于 `SELECT`/`WITH`/`SHOW`/`DESC`/`DESCRIBE`/`EXPLAIN`；
   出现 `INSERT`/`UPDATE`/`DELETE`/`CREATE`/`ALTER`/`DROP`/`TRUNCATE`/`SET`/`GRANT` 等写关键字即拒绝；
   强制单语句（中间分号拒绝）；`/*! ... */` 可执行注释直接拒绝；`INTO OUTFILE`/`FOR UPDATE` 等短语专项拒绝。
2. **服务端只读事务**：语句在 `START TRANSACTION READ ONLY`（`sql.TxOptions{ReadOnly:true}`）中执行，
   即使词法层被绕过，MySQL 也会以 `Error 1792` 拒绝写入。
3. **连接约束**：`multiStatements=false`、`interpolateParams=false`、`context` 超时、
   行数上限与流式截断、`SetMaxOpenConns(1)`。

被拦截时退出码 `3`、stderr 输出 `mysqlq: blocked: ...`、stdout 无数据。
没有 `--allow-write` 之类的逃生开关。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 运行时错误（连接、SQL、超时、表/库不存在、配置缺失） |
| 2 | 用法错误 |
| 3 | 被只读防护拦截 |

## 输出约定

- **stdout 只有数据**，统计/截断/警告一律写 stderr：`[mysqlq] 12 row(s) in 5ms`。
- `--format json`：数组（`schema` 为对象），NULL → `null`，数值 → JSON 数字，日期/字符串 → JSON 字符串，非 UTF-8 二进制 → base64。
- `--format csv`：RFC 4180；NULL 为空字段。`--format md`：GitHub 表格。
- 注意：`columns` 的 CSV 表头首列是 `#`，Windows PowerShell 的 `Import-Csv` 会把以 `#` 开头的行当注释。
  用 PowerShell 解析 CSV 时请改用 `--format json`，或显式传 `-Header`。
- 超过 `--max-rows` 时停止读取并提示 `truncated`。

## 项目结构

```
main.go                 入口
internal/config/        扁平 YAML 子集解析 + 环境变量覆盖
internal/guard/         SQL tokenizer 与只读判定（含单元测试）
internal/db/            连接、只读会话设置、元数据查询、结果扫描
internal/output/        table/json/csv/md 渲染
internal/cli/           子命令与参数解析
config.example.yaml     配置示例（复制为 config.yaml 使用；config.yaml 不入库）
scripts/env.ps1         构建环境
scripts/build.ps1       构建脚本
scripts/ci.ps1          gofmt + go vet + go test
scripts/acceptance.ps1  验收脚本（拦截矩阵 + 行数限制 + 完整性）
scripts/verify/         独立黑盒验证脚本与报告
docs/SPEC.md            规格说明
docs/VERIFICATION.md    验证报告
```

## 开发与测试

本机只有 Windows PowerShell 5.1（没有 `pwsh`），执行策略默认禁止运行脚本，因此统一用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ci.ps1           # gofmt + vet + test
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\acceptance.ps1   # 验收：拦截矩阵 + 行数限制
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify\verify.ps1 # 独立黑盒验证
```

需要单独跑 go 命令时先设置构建环境：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". .\scripts\env.ps1; go vet ./..."
```

## 已知限制

- 只支持单条 SQL，不支持存储过程、多结果集、`SELECT ... INTO`。
- `SHOW`/`DESC`/`EXPLAIN` 允许，但 `EXPLAIN UPDATE ...` 这类含写关键字的语句会被一并拦截（安全优先）。
- 表行数来自 `information_schema` 统计信息，可能不精确；需要精确值请用 `COUNT(*)`。
- 面向 MySQL 5.7 / 8.0 语法。