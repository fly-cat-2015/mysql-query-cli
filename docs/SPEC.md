# mysqlq — 规格说明（权威版）

一个用 Go 编写的 **MySQL 只读查询命令行工具**，面向 AI agent 使用。
工作目录：`E:\code\go\mysql-query-cli`（源码仓库根目录，同时也是部署目录）。

---

## 0. 硬性约束（不可协商）

1. **只读**。工具只允许执行查询类语句。任何可能修改数据/结构/权限/会话状态的语句（INSERT/UPDATE/DELETE/REPLACE、CREATE/ALTER/DROP/TRUNCATE/RENAME、GRANT/REVOKE、SET、CALL、LOAD、SELECT ... INTO OUTFILE 等）必须在**发送到 MySQL 之前**被拦截，向 stderr 报错，并以退出码 `3` 结束。
2. 不提供任何绕过开关（没有 `--allow-write`、没有 `--unsafe`、没有环境变量逃生口）。
3. 拦截必须是"默认拒绝"策略：白名单确定语句类型 + 黑名单关键字 + 单语句检查，任何拿不准的情况一律拦截。
4. 拦截 + 服务端只读事务双重防护：即使词法检查被绕过，MySQL 也必须拒绝写入。
5. 除 `go-sql-driver/mysql` 外不引入第三方依赖（配置解析自己实现，不用 yaml 库；命令行解析用标准库 `flag`，不用 cobra）。

---

## 1. 产物与目录布局

**部署布局**：`mysqlq.exe`、`config.yaml`、`SKILL.md` 放在**同一个目录**（即仓库根目录），
整体复制到任何位置都能直接运行；工具默认读取**可执行文件所在目录**的 `config.yaml`，与当前工作目录无关。

```
mysql-query-cli/           # 源码仓库根目录 = 部署目录
  mysqlq.exe               # 构建产物（与 config.yaml、SKILL.md 同目录；*.exe 不入库）
  config.yaml              # 本地配置（不入库）
  config.example.yaml      # 配置示例（入库）
  SKILL.md                 # 给 AI 的使用说明（入库，与可执行文件同目录）
  go.mod  go.sum
  main.go                  # 极薄，调用 internal/cli.Execute()
  internal/config/         # 配置加载（扁平 YAML 子集 + 环境变量覆盖）
  internal/guard/          # SQL 词法分析 + 只读拦截（含单元测试）
  internal/db/             # 连接、只读会话、查询执行、元数据查询
  internal/output/         # table / json / csv / md 渲染
  internal/cli/            # 子命令与参数解析
  scripts/env.ps1          # 构建环境
  scripts/build.ps1        # 构建到根目录 mysqlq.exe
  scripts/verify/          # 验证脚本（由验证同学维护）
  docs/SPEC.md             # 本文件
  docs/VERIFICATION.md     # 验证报告（由验证同学维护）
  README.md                # 人类说明（由 Lead 维护）
```

二进制名 `mysqlq`，构建输出 `mysqlq.exe`（仓库根目录，与配置和 SKILL.md 同级）。

**构建环境**：任何 `go` 命令前先 `. .\scripts\env.ps1`（把 GOCACHE/GOMODCACHE 放到工作区 `.cache`，`GOSUMDB=off`）。
`powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1` 即可构建
（本机只有 Windows PowerShell 5.1，没有 `pwsh`；脚本本身与 PS 5.1 兼容）。

---

## 2. 配置文件

```yaml
db_host: 127.0.0.1
db_port: 3306
db_name: your_database
db_user: your_user
db_passwd: your_password
max_rows: 20
```

（示例见仓库根目录 `config.example.yaml`；本地 `config.yaml` 不入库。）

- 解析规则：逐行读取，忽略空行和 `#` 开头的注释；`key: value`，key/value 两端去空白；value 可被单引号或双引号包裹（去掉引号）；`#` 出现在值中间时**不**当作注释（避免密码被截断）。
- 支持键（大小写不敏感）：`db_host`、`db_port`（默认 3306）、`db_name`、`db_user`、`db_passwd`（别名 `db_password`）、`db_charset`（默认 utf8mb4）、`max_rows`（默认 20，取值 1..100，>100 钳制为 100 并警告）。
- `max_rows` 非整数或 <1 → 配置错误，exit 1，消息说明合法范围；>100 → 钳制为 100，stderr 警告 `[mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100`。
- 未知键：忽略（不报错）。
- 查找顺序（第一个存在者胜出）：
  1. `--config <path>`（命令行显式指定）
  2. 环境变量 `MYSQLQ_CONFIG`
  3. **可执行文件所在目录的 `config.yaml`**（默认；即 `mysqlq.exe` 同目录，与 SKILL.md 同级）
  4. `./config.yaml`（当前工作目录，兜底：`go run .` 等二进制不在部署目录的场景）
- 查找顺序与"当前工作目录"无关：从任意目录调用 `mysqlq.exe`，默认都读它自己旁边的 `config.yaml`。
- 都找不到：stderr 报错并 exit 1，提示把 `config.yaml` 放到 `mysqlq.exe` 同目录，或用 `--config` 指定。
- 环境变量覆盖（在文件之后生效）：`MYSQLQ_HOST`、`MYSQLQ_PORT`、`MYSQLQ_DB`、`MYSQLQ_USER`、`MYSQLQ_PASSWORD`。
- **密码永不进入任何输出**（`info`、日志、错误信息都不打印）。

---

## 3. 命令行总览

```
mysqlq [全局参数] <command> [参数] [命令参数]
```

全局参数（每个子命令都接受，可放在子命令之后）：

支持 `--` 终止符：`--` 之后的所有参数都按位置参数处理（用于以 `-`/`--` 开头的 SQL，
例如 `mysqlq --format json query -- '-- note
SELECT 1'`）；注意 `--` 之后的 `--format` 不再被解析为 flag。

| 参数 | 说明 | 默认 |
|---|---|---|
| `-c, --config <path>` | 配置文件路径 | 见 §2 |
| `--db <name>` | 覆盖数据库名 | 配置文件 `db_name` |
| `--format <table\|json\|csv\|md>` | 输出格式 | `table` |
| `--timeout <dur>` | 查询超时，`10s`/`500ms`/`2m` | `30s` |
| `--max-rows <n>` | 最大返回行数，**只允许 1..100**，越界 exit 2 | `20`（config `max_rows` 可调） |
| `-h, --help` | 帮助 | |

**返回行数限制（硬性规则）**：
- 默认单次最多返回 **20 行**；可通过 config.yaml 的 `max_rows` 调整。
- **绝对硬上限 100 行**，任何来源都不得超过：`--max-rows` 越界直接 exit 2；config 超过则钳制为 100。
- 优先级：`--max-rows` > config `max_rows` > 默认 20；钳制在最终生效值上做。
- 达到上限即停止读取（不把整表拉入内存），stderr 提示 `[mysqlq] truncated to N row(s) (--max-rows)`，N 为实际生效上限。

子命令：

| 命令 | 作用 |
|---|---|
| `info` | 连接信息、服务器版本、只读状态、当前数据库、配置来源 |
| `databases`（别名 `dbs`） | 列出数据库 |
| `tables [--all]` | 列出当前库的表/视图 |
| `columns <table>` | 表的列结构 |
| `indexes <table>` | 表的索引 |
| `ddl <table>` | `SHOW CREATE TABLE` 原文 |
| `schema <table>` | 列 + 索引 + DDL 的组合视图（agent 一次性了解表） |
| `query <sql>` / `<sql>` 为 `-` 时从 stdin 读 | 执行只读 SQL |
| `explain <sql>` / `-` 同上 | 输出该只读语句的执行计划（经典 `EXPLAIN` 结果集） |
| `find <keyword>` | 在库内按表名/列名/注释模糊搜索 |
| `version` | 工具版本 |

未给子命令时打印用法到 stdout 并 exit 2（缺命令算用法错误）。

### 3.1 `info`

表格列：`KEY`, `VALUE`。行（顺序固定）：
`tool_version`、`config_file`、`host`、`port`、`database`、`user`、`server_version`、`read_only`（恒为 `true`）、`default_max_rows`（最终生效值，含 config 覆盖与 100 钳制后的结果）、`default_timeout`。

### 3.2 `databases`

列：`DATABASE`, `CHARSET`, `COLLATION`，按名字排序。
默认排除系统库：`information_schema`、`mysql`、`performance_schema`、`sys`；`--all` 时包含。

### 3.3 `tables`

列：`TABLE`, `TYPE`, `ENGINE`, `ROWS`, `COMMENT`，按表名排序。
数据源 `information_schema.TABLES`，`ROWS` 取 `TABLE_ROWS` 估算值（可能为 NULL）。
`--all` 包含当前库所有对象，否则一样（本命令无过滤差异，`--all` 只为兼容保留：包含视图）。
视图 `TYPE` 显示 `VIEW`，`ENGINE` 为 NULL。

### 3.4 `columns <table>`

列：`#`、`COLUMN`、`TYPE`、`NULL`（`YES`/`NO`）、`KEY`、`DEFAULT`、`EXTRA`、`COMMENT`，按 `ORDINAL_POSITION` 排序。
`TYPE` 用 `COLUMN_TYPE`（含长度/枚举值）。表不存在 → exit 1，错误信息包含库名和表名。

### 3.5 `indexes <table>`

列：`INDEX`、`UNIQUE`（`YES`/`NO`）、`COLUMNS`（按 `SEQ_IN_INDEX` 逗号拼接，只列名）、`TYPE`、`COMMENT`。主键排最前，其余按名字排序。

### 3.6 `ddl <table>`

- `--format table`：直接输出 `SHOW CREATE TABLE` 第二列原文（多行，不做对齐）。
- `--format json`：`[{"TABLE":"<name>","DDL":"<ddl>"}]`。
- `--format csv/md`：单行记录，DDL 作为单个字段。

### 3.7 `schema <table>`

组合视图。`--format json` 输出**对象**（唯一例外，不是数组）：

```json
{
  "database": "bbc",
  "table": "sale_order",
  "columns": [{"COLUMN": "...", "TYPE": "...", "NULL": "YES", "KEY": "", "DEFAULT": null, "EXTRA": "", "COMMENT": ""}],
  "indexes": [{"INDEX": "PRIMARY", "UNIQUE": "YES", "COLUMNS": "id", "TYPE": "BTREE", "COMMENT": ""}],
  "ddl": "CREATE TABLE ..."
}
```

`--format table`：依次打印 `== columns ==`、`== indexes ==`、`== ddl ==` 三段（段标题打印到 stdout）。

### 3.8 `query <sql>`

- SQL 可来自参数（推荐单引号包裹），或 `-` 表示读 stdin（便于 heredoc/管道）。
- 走只读拦截 + 只读事务执行（见 §6）。
- 输出：实际结果集的列与行。`--format json` 时为对象数组。
- 多结果集不支持（工具强制单语句）。
- 无结果集（例如理论上不会出现的场景）视为错误。

### 3.9 `find <keyword>`

`keyword` 大小写不敏感；**不含** `%`/`_` 时自动按 `%keyword%` 模糊匹配，含有通配符时按原样透传 LIKE（便于精确控制）。
列：`KIND`（`TABLE`/`COLUMN`）、`TABLE`、`COLUMN`、`TYPE`、`COMMENT`。
先列匹配的表，再列匹配的列，各自按名字排序。匹配范围：表名、表注释、列名、列注释。

### 3.10 `explain <sql>`

在只读事务中执行 `EXPLAIN <sql>`，输出 MySQL 经典执行计划（与 `query` 共用同一套只读防护、
超时与行数上限）：

- 参数与 stdin 约定同 `query`（`-` 表示从 stdin 读）。
- 输出列即 MySQL 返回的计划列（MySQL 8：`id`、`select_type`、`table`、`partitions`、`type`、
  `possible_keys`、`key`、`key_len`、`ref`、`rows`、`filtered`、`Extra`），四种 `--format` 均适用。
- SQL 已以 `EXPLAIN`/`DESC`/`DESCRIBE` 开头时**原样执行**（不再叠加前缀，避免语法错误，
  并保留 `EXPLAIN FORMAT=JSON ...` 这类写法）；其余情况自动补 `EXPLAIN ` 前缀。
- 写语句（如 `explain 'INSERT ...'`）仍由 §6.2 拦截，exit 3，不连库。
- 不做计划解读：不输出任何启发式建议，计划由调用方（agent）自行判断。

### 3.11 `version`

stdout 打印 `mysqlq <version>`（版本常量写在 `internal/cli`，形如 `1.0.0`）。

---

## 4. 输出格式

**stdout 只放数据**；行数统计、截断提示、警告一律写 **stderr**，格式：

```
[mysqlq] 12 row(s) in 5ms
[mysqlq] truncated to 20 row(s) (--max-rows)
[mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100
[mysqlq] warning: ...
```

### 4.1 table（默认）

- `+---+---+` 边框可选：**不要边框**，采用无边框对齐表格：表头一行、分隔行 `----`、数据按列宽左对齐（数值列可用右对齐，可省略）。
- 单元格换行/制表符替换为空格，避免破坏对齐。
- NULL 显示为 `NULL`；空字符串显示为空。
- 空结果集：只打印表头与分隔行（stderr 有 `[mysqlq] 0 row(s)`）。

### 4.2 json

- **美化输出**：2 空格缩进，UTF-8 原文（不转义中文），末尾换行。
- 数组元素为对象，key 为列名（大写形式与查询返回一致）。
- 类型映射：SQL NULL → `null`；整数/小数（TINYINT..BIGINT、DECIMAL、FLOAT/DOUBLE）→ JSON 数字（用 `json.Number`，保留 DECIMAL 精度）；其余（字符串、日期时间、二进制、JSON 列）→ JSON 字符串；`[]byte` 先按 UTF-8 校验，非 UTF-8 用 base64 并加 `"__base64__":true`？——**不做额外封装**，非 UTF-8 二进制直接 base64 字符串（保持简单）。
- `--format json` 一定输出合法 JSON（错误时 stdout 为空）。

### 4.3 csv

RFC 4180：逗号分隔，字段含逗号/引号/换行时用双引号包裹并转义；首行表头；NULL 输出为空字段；行尾 `\r\n`。

### 4.4 md

GitHub 风格 Markdown 表格；单元格中的 `|` 转义为 `\|`，换行替换为 `<br>`；NULL 输出为 `NULL`。

---

## 5. 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 运行时错误（连接失败、SQL 执行错误、表不存在、配置缺失等） |
| 2 | 用法错误（未知命令、缺参数、非法 flag 值） |
| 3 | 被只读防护拦截（**必须**是这个词：`blocked`） |

错误统一格式（stderr）：`mysqlq: <类别>: <消息>`，类别为 `error` / `usage` / `blocked` / `config`。
拦截时消息必须包含被拦截的关键字或原因，例如：

```
mysqlq: blocked: statement contains forbidden keyword "INSERT"; this tool only allows read-only queries
```

---

## 6. 只读防护（核心，必须逐条实现）

### 6.1 词法分析（`internal/guard`）

不要用正则做整体判断。实现一个 tokenizer，把 SQL 拆成 token（保留原始位置用于错误提示）：

- 跳过空白。
- 注释：`-- `（`--` 后必须跟空白或行尾，MySQL 规则）、`#` 到行尾、`/* ... */`。
  **特别规则**：`/*!` 开头的可执行注释（versioned comment）**直接拦截**（MySQL 会执行其内容）；`/*+` optimizer hint 允许（不可执行写操作），按普通注释跳过。
- 字符串：`'...'` 与 `"..."`，处理 `\\` 转义和 `''`/`""` 双写；字符串内容不参与关键字判断。
- 反引号标识符：`` `...` ``（含 `` `` `` 双写转义），内容不参与关键字判断（即 `SELECT \`set\` FROM t` 是合法的）。
- 标识符/关键字：字母、数字、`_`、`$`、`.`（保留 `.` 作为限定符也可拆成标点）、以及 ≥0x80 的 Unicode 字母。
- 数字字面量、标点 `( ) , . * = < > ! + - / % @ : ?` 等单字符 token。
- `;` 单独成为 token。

### 6.2 判定规则

1. 空语句 → 拦截（`empty statement`）。
2. 语句长度 > 64KB → 拦截。
3. **单语句**：去掉末尾空白后，只允许最多一个结尾 `;`；任何出现在中间的 `;` → 拦截（`multiple statements are not allowed`）。
4. **首 token 白名单**：`SELECT`、`WITH`、`SHOW`、`DESC`、`DESCRIBE`、`EXPLAIN`。其它一律拦截（含 `TABLE`、`VALUES`）。
   - `WITH` 必须再通过黑名单（见下，因为 MySQL 支持 `WITH ... DELETE/UPDATE`）。
5. **黑名单关键字**（作为 WORD token 出现即拦截，大小写不敏感；字符串/反引号内容不算）：
   `INSERT UPDATE DELETE REPLACE MERGE UPSERT CREATE ALTER DROP TRUNCATE RENAME GRANT REVOKE SET RESET CALL DO LOAD IMPORT HANDLER FLUSH KILL SHUTDOWN INSTALL UNINSTALL PREPARE EXECUTE DEALLOCATE XA START BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE LOCK UNLOCK OPTIMIZE ANALYZE REPAIR CHECKSUM USE INTO OUTFILE DUMPFILE BACKUP RESTORE PURGE`
6. **短语检查**（token 序列相邻匹配）：`FOR SHARE`、`LOCK IN SHARE MODE`、`INTO OUTFILE`、`INTO DUMPFILE` → 拦截（`INTO` 已在黑名单，仍保留显式检查以便给出更清晰原因）。
7. 拦截必须**先于**任何与数据库的交互（不能先连库再判断）；连库前完成 guard。
8. 单元测试必须覆盖：正例（SELECT/WITH/SHOW/DESC/DESCRIBE/EXPLAIN、含字符串里的 `DELETE`、反引号 `\`update\``、`SELECT 1;`）；反例（见 §9 矩阵）。

### 6.3 执行期防护（`internal/db`，纵深防御）

1. 连接串固定 `multiStatements=false`、`interpolateParams=false`、`readTimeout`/`writeTimeout` 与超时一致。
2. 会话建立后（在同一条连接上）执行：
   - `SET SESSION TRANSACTION READ ONLY`（失败则降级为仅用事务级只读，不报错、不退出）
   - `SET SESSION max_execution_time = <timeout 毫秒>`（失败则忽略）
   - `SET SESSION time_zone = '+00:00'`? 不需要，跳过。
3. 用户 SQL 在 `sql.TxOptions{ReadOnly: true}` 事务中执行（`BeginTx`），结束后 `Rollback`（只读，无副作用）。
4. 使用 `context.WithTimeout` 控制总耗时；超时 exit 1，消息注明 timeout。
5. 逐行扫描并**在达到生效行数上限时停止读取**（不把整表拉进内存），stderr 提示 truncated。
   生效上限 = min(命令行 --max-rows 或 config max_rows 或 20, **100**)——`100` 是代码里的常量硬顶，
   任何配置/参数组合都不得突破。
6. 会话是一条连接且用完即关（`db.SetMaxOpenConns(1)`），避免只读会话设置被其它连接绕过。

> 注意：`SHOW CREATE TABLE`、`information_schema` 查询都是只读，但也要走同一连接/事务路径。

---

## 7. 测试要求

- `internal/guard/guard_test.go`：表驱动单元测试，正例/反例（§9 矩阵中的词法部分）。
- `go vet ./...` 干净。
- 所有命令在真实 MySQL 8.0.33（`config.yaml` 指向的 `bbc` 库，12 张表）上手工跑通。
- **拦截矩阵**（黑盒，用真库实测，每次执行后必须验证数据/结构未变）：
  - 数据写：`INSERT INTO sale_pay ...`、`UPDATE sale_pay SET ...`、`DELETE FROM sale_pay ...`、`REPLACE INTO ...`
  - 结构改：`CREATE TABLE t_x(...)`、`ALTER TABLE sale_pay ADD COLUMN ...`、`DROP TABLE sale_pay`、`TRUNCATE sale_pay`、`RENAME TABLE ...`
  - 权限/会话：`GRANT SELECT ON *.* TO x`、`SET SESSION TRANSACTION READ WRITE`
  - 注入/多语句：`SELECT 1; DROP TABLE sale_pay`、`SELECT 1 INTO OUTFILE '/tmp/x'`
  - 注释/大小写绕过：`/*x*/ INSERT INTO ...`、`insert   into`、`InSeRt`、`WITH a AS (SELECT 1) DELETE FROM sale_pay`、`WITH a AS (SELECT 1) UPDATE sale_pay SET ...`
  - 每条都必须 exit 3、stdout 无数据、且 `SELECT COUNT(*)` 前后一致。

---

## 8. 验证 / 交付标准

1. `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1` 成功，根目录 `mysqlq.exe` 可用。
2. `mysqlq info` 正确显示服务器版本 `8.0.33`、库 `bbc`，且不泄露密码。
3. `databases`、`tables`、`columns sale_pay`、`indexes sale_pay`、`ddl sale_pay`、`schema sale_pay`、`query 'SELECT ...'`、`find order` 全部正常，四种格式都合法。
4. §7 拦截矩阵全部 exit 3，数据零变化。
5. **行数限制**：默认查询返回不超过 20 行（用 `information_schema.COLUMNS` 这类多行结果集验证）；
   config `max_rows: 5` 生效返回 5 行；config `max_rows: 500` 钳制为 100 且 stderr 有 warning；
   `--max-rows 101` exit 2；`--max-rows 5` 返回 5 行且 stderr 有 truncated；任何情况下行数 ≤ 100。
6. `--help` 可用，未知命令 exit 2。
7. `SKILL.md` 与真实行为一致（Lead 负责）。

---

## 9. 交付物清单

- Go 源码（上述布局）、`go.mod`/`go.sum`、`mysqlq.exe`（根目录，与 config.yaml、SKILL.md 同级）
- `docs/VERIFICATION.md`（验证同学：命令 + 期望 + 实际结果 + 拦截矩阵证据）
- `SKILL.md`、`README.md`（Lead）