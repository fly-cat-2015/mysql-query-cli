# mysqlq 只读查询 CLI — 独立黑盒验证报告

> 验证对象：`E:\code\go\mysql-query-cli`（二进制 `bin\mysqlq.exe`）
> 规格依据：`docs/SPEC.md`（§3 命令/参数、§4 输出格式、§5 退出码、§6 只读防护、§8 验收标准）
> 验证方式：**纯黑盒**。未读取、未修改任何 Go 源码；仅通过进程调用二进制并与独立 `mysql.exe` 客户端交叉核对数据。

## 0. 结论摘要

| 项目 | 结果 |
| --- | --- |
| 验证用例总数 | 326 |
| PASS | 324 |
| WARN（互操作提示，非功能/安全缺陷） | 2 |
| FAIL | 0 |
| [BLOCKER] | **0** |
| 二进制 SHA256 是否在验证期间变化 | 否（前后一致，`7C0A02C9122730BBC23CF18AB61560B6...`） |
| 拦截后数据/结构是否变化 | 否（45 条拦截用例逐条双客户端核对 + 全量结束复核，均为 12/2/11/0/0） |
| **总体结论** | **可交付（PASS）**：功能、退出码、四种格式、配置优先级、只读拦截、行数硬上限、超时防护均符合 SPEC；仅 2 项 CSV 互操作提示（见 §11），不影响数据安全与核心功能 |

## 1. 环境与方法

### 1.1 环境信息

| 项目 | 值 |
| --- | --- |
| 主机/工作目录 | `E:\code\go\mysql-query-cli` |
| 二进制 | `E:\code\go\mysql-query-cli\bin\mysqlq.exe` |
| 二进制大小 | 8,228,352 字节 |
| 二进制 SHA256 | `7C0A02C9122730BBC23CF18AB61560B62F0AEC1B684AA7238F7426BE0FDDB4B0` |
| 配置文件 | `E:\code\go\mysql-query-cli\config.yaml`（未修改） |
| MySQL 服务器 | 8.0.33（127.0.0.1:3306，库 `bbc`，用户 root） |
| 独立 mysql 客户端 | `D:\bin\mysql-8.0.33-winx64\bin\mysql.exe`（交叉核对用） |
| 验证脚本宿主 | Windows PowerShell 5.1.26100.9711（无 pwsh） |
| 验证时间 | 2026-10-29 21:31:51 |
| 基线（验证前后一致） | 12 张表；`sale_pay`=2 行；`after_sale_reason`=11 行；`sale_pay_rel`=0 行；无 `zz_probe`/`sale_pay_bak`/`t_x` 等残留 |

### 1.2 方法说明

- **黑盒约束**：全程只调用 `bin\mysqlq.exe` 与独立 `mysql.exe`；未读取 `internal/`、`main.go` 等实现代码；未修改 `config.yaml`、`docs/SPEC.md`、`SKILL.md`、`README.md`、`scripts/acceptance.ps1`、`bin/`，写作用域仅 `scripts/verify/**` 与本文档。
- **输出捕获**：使用 `System.Diagnostics.Process` 分别捕获 stdout/stderr（UTF-8 解码）。原因：PowerShell 5.1 用 `2> file` 会把原生进程 stderr 包装成 `NativeCommandError` 文本，污染“stderr 是否含 blocked / 是否出现驱动日志”的断言；同时 `&` 调用运算符在 PS 5.1 下会丢弃空字符串参数，无法构造“空语句”用例。
- **每例证据**：命令、期望、实际（exit code + stdout 字节数 + stderr 摘要 + 关键 stdout 断言）、结论。完整 326 例原始证据见 `scripts/verify/last-run.log` / `scripts/verify/last-run.md`（由脚本自动生成、可重复执行）。
- **只读拦截后的完整性**：每条拦截用例后立即用 mysqlq 执行计数查询，并用独立 `mysql.exe` 再核对一次：表数量=12、`sale_pay`=2、`after_sale_reason`=11、`sale_pay_rel`=0、残留表=0；全部跑完后再整体复核一次。
- **二进制不可变性**：验证开始与结束各取一次 SHA256，确认期间无人重建二进制。
- **复现命令**：`powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify\verify.ps1`（退出码 0=全部 PASS，1=存在 FAIL）。

### 1.3 结果分组统计

| 分组 | 用例数 | PASS | WARN | FAIL |
| --- | --- | --- | --- | --- |
| env | 3 | 3 | 0 | 0 |
| baseline | 4 | 4 | 0 | 0 |
| commands | 29 | 29 | 0 | 0 |
| formats | 105 | 103 | 2 | 0 |
| format-detail | 18 | 18 | 0 | 0 |
| exitcodes | 22 | 22 | 0 | 0 |
| config | 19 | 19 | 0 | 0 |
| guard | 55 | 55 | 0 | 0 |
| integrity | 46 | 46 | 0 | 0 |
| defense | 13 | 13 | 0 | 0 |
| limits | 10 | 10 | 0 | 0 |
| timeout | 2 | 2 | 0 | 0 |

## 2. 全命令验证（SPEC §3 / §8.3）

所有命令均走真实库 `bbc`，退出码 0，stdout 只有数据，行数统计/截断提示只走 stderr。

| 用例 | 期望 | 实际（exit/stdout/stderr 摘要） | 结论 |
| --- | --- | --- | --- |
| cmd-01 | `version` 输出 `mysqlq 1.0.0`，exit 0 | exit=0; stdout=13B; stderr: | PASS |
| cmd-01b | `version` 标准输出恰好一行、无多余内容 | [mysqlq 1.0.0] | PASS |
| cmd-02 | `info` 输出 10 个 KEY/VALUE 行：8.0.33 / bbc / read_only=true / 不含密码 | exit=0; stdout=349B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cmd-02b | `info` 的 stdout+stderr 不含密码值 | leaks=0 | PASS |
| cmd-02c | `info` 行顺序固定：tool_version→config_file→host→port→database→user→server_version→read_only→default_max_rows→default_timeout | KEY > ---------------- > tool_version > config_file > host > port > database > user > server_version > read_only > default_max_rows > defau... | PASS |
| cmd-03 | `databases` 默认排除 4 个系统库，按名字排序 | exit=0; stdout=1669B; stderr: [mysqlq] 17 row(s) in 1ms \| | PASS |
| cmd-03b | `databases` 默认返回 17 个非系统库 | count=17 sorted=True | PASS |
| cmd-04 | `databases --all` 含 information_schema/mysql/performance_schema/sys | exit=0; stdout=2085B; stderr: [mysqlq] 21 row(s) in 1ms \| | PASS |
| cmd-04b | `databases --all` 共 21 行（配合 --max-rows 100） | count=21 | PASS |
| cmd-05 | `tables` 返回 12 表，列 TABLE/TYPE/ENGINE/ROWS/COMMENT，含中文注释 | exit=0; stdout=1526B; stderr: [mysqlq] 12 row(s) in 2ms \| | PASS |
| cmd-05b | `tables` 计数 12，`sale_pay` 的 ROWS 估算=2 | count=12 sale_pay.ROWS=2 | PASS |
| cmd-06 | `tables --all` 可用，exit 0 | exit=0; stdout=1526B; stderr: [mysqlq] 12 row(s) in 2ms \| | PASS |
| cmd-07 | `columns sale_pay` 18 列，列顺序含 `#`/COLUMN/TYPE/NULL/KEY/DEFAULT/EXTRA/COMMENT | exit=0; stdout=3156B; stderr: [mysqlq] 18 row(s) in 2ms \| | PASS |
| cmd-07b | `columns` 计数 18 与独立 mysql 客户端一致，`#` 严格 1..18 | count=18 mysql_client=18 ordered=True headers=True | PASS |
| cmd-08 | `indexes sale_pay` 4 个索引，主键 PRIMARY 排最前，其余按名排序，COLUMNS 逗号拼接 | exit=0; stdout=515B; stderr: [mysqlq] 4 row(s) in 2ms \| | PASS |
| cmd-08b | `indexes` 计数 4 与独立 mysql 客户端一致 | count=4 mysql_client=4 primary_first=True | PASS |
| cmd-09 | `ddl sale_pay` 输出 `SHOW CREATE TABLE` 原文（含 AUTO_INCREMENT） | exit=0; stdout=1353B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cmd-09b | `ddl` table 格式不做对齐表格（无 `----`），为多行原文 | lines=25 hasSeparator=False | PASS |
| cmd-10 | `schema sale_pay` table 格式依次打印 `== columns ==`、`== indexes ==`、`== ddl ==` | exit=0; stdout=3848B; stderr: [mysqlq] 18 row(s) in 2ms \| [mysqlq] 4 row(s) in 1ms \| [mysqlq] 1 row(s) in 0ms \| | PASS |
| cmd-11 | `query "SELECT 1 AS one"` 正常返回 | exit=0; stdout=12B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cmd-12 | `query -` 从 stdin 读 SQL 并执行 | exit=0; stdout=29B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cmd-13 | `find order` 结果含 KIND=TABLE/COLUMN 两类 | exit=0; stdout=2837B; stderr: [mysqlq] 20 row(s) in 3ms \| | PASS |
| cmd-13b | `find` 行序：匹配表在前、匹配列在后 | count=20 order_ok=True | PASS |
| cmd-14 | `find` 关键字大小写不敏感（SALE_ORDER 命中 sale_order） | exit=0; stdout=127B; stderr: [mysqlq] 1 row(s) in 2ms \| | PASS |
| cmd-15 | `find` 关键字含 `%` 时按 LIKE 透传（sale% 命中 sale_order/sale_pay） | exit=0; stdout=1034B; stderr: [mysqlq] 8 row(s) in 3ms \| | PASS |
| cmd-16 | `find` 无匹配返回 0 行，exit 0 | exit=0; stdout=3B; stderr: [mysqlq] 0 row(s) in 3ms \| | PASS |
| cmd-17 | `dbs` 别名等价于 `databases` | exit=0; stdout=1669B; stderr: [mysqlq] 17 row(s) in 1ms \| | PASS |
| cmd-18 | `--help` exit 0，含全部命令与全局参数说明 | exit=0; stdout=1947B; stderr: | PASS |
| cmd-18b | `--help` stderr 为空（帮助属数据，写 stdout） | stderr=0B | PASS |

## 3. 四种输出格式矩阵（SPEC §4）

对 10 个命令 × 4 种格式执行 40 次，并逐项校验：json 可被 `ConvertFrom-Json` 解析；csv 可被 `Import-Csv` 解析且行尾为 CRLF；md 含 `|` 表头与 `---` 分隔行；table 为无边框对齐表格。

| 命令 | table | json | csv | md | 备注 |
| --- | --- | --- | --- | --- | --- |
| info | PASS | PASS | PASS | PASS | json 为对象数组 |
| databases | PASS | PASS | PASS | PASS | json 为对象数组 |
| tables | PASS | PASS | PASS | PASS | json 为对象数组 |
| columns | PASS | PASS | PASS | PASS | CSV 表头首字段为 `#`（SPEC 定义），见 §10 MINOR-1 |
| indexes | PASS | PASS | PASS | PASS | json 为对象数组 |
| ddl | PASS | PASS | PASS | PASS | table 为原始 DDL；json 为 [{"TABLE","DDL"}] |
| schema | PASS | PASS | PASS | PASS | json 为对象（database/table/columns/indexes/ddl）；table 三段 |
| query | PASS | PASS | PASS | PASS | json 为对象数组 |
| find | PASS | PASS | PASS | PASS | json 为对象数组 |
| version | PASS | PASS | N/A | N/A | `version` 忽略 --format，始终纯文本（SPEC 未规定，行为稳定） |

**json 类型证据**：`schema` 的 json 顶层是对象（`{` 开头，含 `database`/`table`/`columns`/`indexes`/`ddl`，实测 `columns`=18、`indexes`=4、`ddl` 以 `CREATE TABLE` 开头）；其余命令的 json 顶层均为数组（`[` 开头）。`info` 的 json 为 10 个 `{KEY,VALUE}`；`ddl` 的 json 为单元素数组 `[{"TABLE":"sale_pay","DDL":"..."}]`。

### 3.1 格式细节（NULL / 转义 / 数值 / 二进制 / 空结果）

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| det-01 | table：SQL NULL 显示 `NULL`，单元格内换行替换为空格，无 `+--+` 边框 | exit=0; stdout=252B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-01b | table：单元格内换行折叠后仍是 1 行数据（表头+分隔+1 数据行=3 行） | datalines=3 | PASS |
| det-02 | json：NULL→null；DECIMAL 保留原文 `1.50`；BIGINT 精确；DATETIME→字符串 | exit=0; stdout=187B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-02b | json：null/引号/内嵌换行经解析后正确回读 | parsed=True | PASS |
| det-02c | json：2 空格缩进、末尾换行且无多余空行 | indent=True trailingLF=True | PASS |
| det-03 | json：中文以 UTF-8 原文输出（不转义为 \uXXXX） | exit=0; stdout=28B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-03b | json：不含 `\u4e2d` 之类的转义 | escaped=False | PASS |
| det-04 | csv：含逗号/双引号/换行的字段正确加引号转义，NULL 为空字段，CRLF 行尾 | exit=0; stdout=106B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-04b | csv：Import-Csv 解析后值可正确还原 | rows=1 b=x,y a=[] | PASS |
| det-05 | md：`\|` 转义为 `\\|`，换行转 `<br>`，NULL 输出 `NULL` | exit=0; stdout=189B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-06 | json：非 UTF-8 二进制按 base64 字符串输出（`UNHEX('FF')`→`"/w=="`） | exit=0; stdout=33B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| det-07 | 空结果集：table 只有表头+分隔行，stderr 有 `[mysqlq] 0 row(s)` | exit=0; stdout=120B; stderr: [mysqlq] 0 row(s) in 0ms \| | PASS |
| det-07b | 空结果 table 无数据行 | lines=2 | PASS |
| det-empty-json | 空结果 json 为 `[]` | exit=0; stdout=3B; stderr: [mysqlq] 0 row(s) in 0ms \| | PASS |
| det-empty-json-valid | 空结果 json 仍是合法 JSON | [] \| | PASS |
| det-empty-csv | 空结果 csv 仅表头，无数据行 | exit=0; stdout=56B; stderr: [mysqlq] 0 row(s) in 1ms \| | PASS |
| det-empty-csv-valid | 空结果 csv 可被 Import-Csv 解析为 0 行 | rows=0 | PASS |
| det-empty-md | 空结果 md 仍有表头与分隔行 | exit=0; stdout=107B; stderr: [mysqlq] 0 row(s) in 1ms \| | PASS |

## 4. 退出码验证（SPEC §5）

退出码约定：0=成功；1=运行时错误；2=用法错误；3=只读拦截（stderr 必须含 `blocked`）。

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| exit-success | 成功查询 → 0 | exit=0; stdout=23B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| exit-unknown-cmd | 未知子命令 → 2，stderr 含 usage | exit=2; stdout=0B; stderr: mysqlq: usage: unknown command "nosuchcmd" (commands: info, databases, tables, columns, indexes, ddl, schema, qu... | PASS |
| exit-missing-arg-columns | `columns` 缺表名 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: columns requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-missing-arg-indexes | `indexes` 缺表名 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: indexes requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-missing-arg-ddl | `ddl` 缺表名 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: ddl requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-missing-arg-schema | `schema` 缺表名 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: schema requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-missing-arg-query | `query` 缺 SQL → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: query requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-missing-arg-find | `find` 缺关键字 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: find requires exactly 1 argument, got 0 (run "mysqlq --help") \| | PASS |
| exit-extra-args | `query` 多余参数 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: query requires exactly 1 argument, got 2 (run "mysqlq --help") \| | PASS |
| exit-version-extra | `version` 多余参数 → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: version takes no arguments, got 1 \| | PASS |
| exit-bad-format | 非法 `--format xml` → 2，提示合法值 | exit=2; stdout=0B; stderr: mysqlq: usage: invalid --format "xml": expected one of table, json, csv, md \| | PASS |
| exit-maxrows-101 | `--max-rows 101` → 2，提示 1..100 | exit=2; stdout=0B; stderr: mysqlq: usage: --max-rows must be between 1 and 100 (got 101) \| | PASS |
| exit-maxrows-0 | `--max-rows 0` → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: --max-rows must be between 1 and 100 (got 0) \| | PASS |
| exit-maxrows-neg | `--max-rows -1` → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: --max-rows must be between 1 and 100 (got -1) \| | PASS |
| exit-unknown-flag | 未知 flag `--nope` → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: unknown flag "--nope" (run "mysqlq --help") \| | PASS |
| exit-bad-timeout | 非法 `--timeout abc` → 2 | exit=2; stdout=0B; stderr: mysqlq: usage: invalid --timeout "abc": expected a positive duration like 10s, 500ms, 2m \| | PASS |
| exit-no-table | 不存在的表 → 1，错误含库名 bbc 与表名 | exit=1; stdout=0B; stderr: mysqlq: error: table "no_such_table" does not exist in database "bbc" (list tables with "mysqlq tables") \| | PASS |
| exit-bad-sql | 坏 SQL/不存在表 → 1，stderr 为 MySQL 错误 | exit=1; stdout=0B; stderr: mysqlq: error: table does not exist: Table 'bbc.no_such_table' doesn't exist (list tables with "mysqlq tables") \| | PASS |
| exit-no-db | 不存在的库 → 1，提示 database does not exist | exit=1; stdout=0B; stderr: mysqlq: error: database "no_such_db" does not exist (check --db or db_name in the config file; list databases wi... | PASS |
| exit-missing-config | `--config` 指向不存在的文件 → 1，提示用 --config | exit=1; stdout=0B; stderr: mysqlq: config: config file "E:\\code\\go\\mysql-query-cli\\scripts\\verify\\tmp\\nope.yaml" (from --config) doe... | PASS |

补充：无子命令时按 SPEC §3 打印 usage 到 **stdout** 并 exit 2（用例 `exit-nocmd` / `exit-nocmd2`，均 PASS，stderr 为空）。

## 5. 配置与环境变量（SPEC §2）

配置查找顺序、环境变量覆盖、`--db` 覆盖、以及“密码永不进入任何输出”均已逐项验证。密码泄露测试使用不会出现在其他字段的唯一哨兵值：`S3cr3tLeak_9z`（不可达端口配置）、`LeakMarker_9z`（错误密码配置 / MYSQLQ_PASSWORD 环境变量）。

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| cfg-explicit | `--config <path>` 生效：info 的 config_file 为该路径，default_max_rows=5 | exit=0; stdout=390B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-env-config | `MYSQLQ_CONFIG` 生效（config_file 指向 env 指定文件，max_rows=5） | exit=0; stdout=390B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-cli-over-env | 优先级 `--config` > `MYSQLQ_CONFIG`（取 max_rows=9 的配置） | exit=0; stdout=394B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-cwd | 无 --config/MYSQLQ_CONFIG 时使用当前目录 `./config.yaml`（max_rows=7） | exit=0; stdout=398B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-env-over-cwd | `MYSQLQ_CONFIG` > 当前目录 config.yaml | exit=0; stdout=398B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-parent-fallback | 查找链后备：在 `bin/` 下运行时能通过 `../config.yaml` 找到根配置 | exit=0; stdout=349B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-quoted | 配置值可用引号包裹（`db_passwd: "root"`）并成功连接 | exit=0; stdout=24B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cfg-unknown-key | 未知配置键被忽略，不报错 | exit=0; stdout=24B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cfg-bad-maxrows | `max_rows: abc` → 配置错误 exit 1，提示 1..100 | exit=1; stdout=0B; stderr: mysqlq: config: invalid max_rows "abc" in E:\code\go\mysql-query-cli\scripts\verify\tmp\cfg_badmax.yam... | PASS |
| cfg-bad-port | 不可达端口 → 运行时错误 exit 1，含 host:port | exit=1; stdout=0B; stderr: mysqlq: error: cannot connect to MySQL at 127.0.0.1:3399: dial tcp 127.0.0.1:3399: connectex: No conne... | PASS |
| cfg-bad-port-noleak | 连接失败错误不打印密码（哨兵 S3cr3tLeak_9z） | leaks=0 | PASS |
| cfg-bad-pw-noleak | Access denied 错误不打印密码（哨兵 LeakMarker_9z） | leaks=0 | PASS |
| cfg-env-pw-noleak | `MYSQLQ_PASSWORD` 哨兵不出现在任何输出 | leaks=0 | PASS |
| cfg-env-pw-exit | 错误 `MYSQLQ_PASSWORD` → exit 1（access denied） | exit=1 | PASS |
| cfg-mysqlq-db | `MYSQLQ_DB=funds` 覆盖 db_name（info 显示 funds） | exit=0; stdout=351B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-db-flag | `--db information_schema` 生效（可列出系统视图，--max-rows 100） | exit=0; stdout=9660B; stderr: [mysqlq] 79 row(s) in 2ms \| | PASS |
| cfg-db-over-env | `--db` 优先于 `MYSQLQ_DB`（显示 bbc 而非 funds） | exit=0; stdout=349B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| cfg-db-funds | `--db funds` 在第二个真实库上查询 `DATABASE()` 正确 | exit=0; stdout=30B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| cfg-env-port | `MYSQLQ_PORT=3399` 生效 → exit 1 连接失败 | exit=1 | PASS |

`info` 正常输出仅 10 行 KEY/VALUE（tool_version/config_file/host/port/database/user/server_version/read_only/default_max_rows/default_timeout），无任何密码字段；另断言输出中不含 `root:root`、`@tcp(`、`db_passwd:`、`password=` 等凭证模式。

## 6. 只读拦截矩阵（SPEC §6 / §7 / §8.4）

**判定标准（每条）**：exit=3、stdout 为空、stderr 含 `blocked`；**每条之后**立即做完整性核对（mysqlq + 独立 mysql 客户端：表数=12、sale_pay=2、after_sale_reason=11、sale_pay_rel=0、残留表=0）。下表“完整性”列均为该条执行后的双客户端结果。

| 编号 | 载荷（SQL） | 场景 | exit | stdout | stderr 摘要 | 完整性 | 结论 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ins-01 | `INSERT INTO sale_pay (id) VALUES (999)` | 数据写：INSERT | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ins-02 | `insert   into sale_pay (id) values (999)` | 小写 + 多空格 INSERT | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ins-03 | `InSeRt INTO sale_pay (id) VALUES (999)` | 大小写混合 INSERT | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ins-04 | `INSERT/*c*/INTO sale_pay (id) VALUES (999)` | 注释分隔 INSERT | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| upd-01 | `UPDATE sale_pay SET pay_status = 0` | 数据写：UPDATE | 3 | 0B | statement contains forbidden keyword "UPDATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| upd-02 | `upDate sale_pay set pay_status=0` | 大小写混合 UPDATE | 3 | 0B | statement contains forbidden keyword "UPDATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| del-01 | `DELETE FROM sale_pay` | 数据写：DELETE | 3 | 0B | statement contains forbidden keyword "DELETE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| del-02 | `DeLeTe FROM sale_pay WHERE id = 2282` | 大小写混合 DELETE | 3 | 0B | statement contains forbidden keyword "DELETE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| rep-01 | `REPLACE INTO sale_pay (id) VALUES (999)` | REPLACE | 3 | 0B | statement contains forbidden keyword "REPLACE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ups-01 | `INSERT INTO sale_pay (id) VALUES (999) ON DUPLICATE KEY UPDATE pay_status=0` | UPSERT（INSERT ... ON DUPLICATE KEY UPDATE） | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ups-02 | `UPSERT INTO sale_pay (id) VALUES (999)` | UPSERT 关键字 | 3 | 0B | statement contains forbidden keyword "UPSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cre-01 | `CREATE TABLE zz_probe (id int)` | 结构改：CREATE | 3 | 0B | statement contains forbidden keyword "CREATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cre-02 | `create table zz_probe (id int)` | 小写 CREATE | 3 | 0B | statement contains forbidden keyword "CREATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| alt-01 | `ALTER TABLE sale_pay ADD COLUMN zz int` | 结构改：ALTER | 3 | 0B | statement contains forbidden keyword "ALTER"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| dro-01 | `DROP TABLE sale_pay` | 结构改：DROP | 3 | 0B | statement contains forbidden keyword "DROP"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| dro-02 | `dRoP tAbLe sale_pay` | 大小写混合 DROP | 3 | 0B | statement contains forbidden keyword "DROP"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| tru-01 | `TRUNCATE sale_pay` | 结构改：TRUNCATE | 3 | 0B | statement contains forbidden keyword "TRUNCATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| ren-01 | `RENAME TABLE sale_pay TO sale_pay_bak` | 结构改：RENAME | 3 | 0B | statement contains forbidden keyword "RENAME"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| gra-01 | `GRANT SELECT ON *.* TO x` | 权限：GRANT | 3 | 0B | statement contains forbidden keyword "GRANT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| rev-01 | `REVOKE SELECT ON *.* FROM x` | 权限：REVOKE | 3 | 0B | statement contains forbidden keyword "REVOKE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| set-01 | `SET SESSION TRANSACTION READ WRITE` | 会话：SET | 3 | 0B | statement contains forbidden keyword "SET"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cal-01 | `CALL some_proc()` | CALL | 3 | 0B | statement contains forbidden keyword "CALL"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| loa-01 | `LOAD DATA INFILE 'x' INTO TABLE sale_pay` | LOAD | 3 | 0B | statement contains forbidden keyword "LOAD"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| exp-01 | `EXPORT` | EXPORT（首 token 非白名单） | 3 | 0B | statement must start with one of SELECT, WITH, SHOW, DESC, DESCRIBE, EXPLAIN; got "EXPORT" | 12/2/11/0/0 ✔ | PASS |
| use-01 | `USE mysql` | USE | 3 | 0B | statement contains forbidden keyword "USE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| inj-01 | `SELECT 1; DROP TABLE sale_pay` | 多语句注入 DROP | 3 | 0B | multiple statements are not allowed (found ";" in the middle of the statement) | 12/2/11/0/0 ✔ | PASS |
| inj-02 | `SELECT 1; DELETE FROM sale_pay` | 多语句注入 DELETE | 3 | 0B | multiple statements are not allowed (found ";" in the middle of the statement) | 12/2/11/0/0 ✔ | PASS |
| inj-03 | `SELECT 1; UPDATE sale_pay SET pay_status=0` | 多语句注入 UPDATE | 3 | 0B | multiple statements are not allowed (found ";" in the middle of the statement) | 12/2/11/0/0 ✔ | PASS |
| cmt-01 | `/*x*/ INSERT INTO sale_pay (id) VALUES (999)` | 块注释绕过：/*x*/ INSERT | 3 | 0B | statement contains forbidden keyword "INSERT"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cmt-02 | `-- note\nDROP TABLE sale_pay` | 行注释后 DROP | 3 | 0B | statement contains forbidden keyword "DROP"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cmt-03 | `# note\nDROP TABLE sale_pay` | `#` 注释后 DROP | 3 | 0B | statement contains forbidden keyword "DROP"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cmt-04 | `/*!50000 DROP TABLE sale_pay */` | 可执行版本注释 /*!...*/ | 3 | 0B | cannot safely parse statement: versioned comment /*! ... */ is not allowed (MySQL executes its content) at li... | 12/2/11/0/0 ✔ | PASS |
| cte-01 | `WITH a AS (SELECT 1) DELETE FROM sale_pay` | CTE + DELETE | 3 | 0B | statement contains forbidden keyword "DELETE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| cte-02 | `WITH a AS (SELECT 1) UPDATE sale_pay SET pay_status=0` | CTE + UPDATE | 3 | 0B | statement contains forbidden keyword "UPDATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| out-01 | `SELECT 1 INTO OUTFILE 'C:/tmp/x'` | INTO OUTFILE | 3 | 0B | statement contains forbidden phrase "INTO OUTFILE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| out-02 | `SELECT 1 INTO DUMPFILE 'C:/tmp/x'` | INTO DUMPFILE | 3 | 0B | statement contains forbidden phrase "INTO DUMPFILE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| lck-01 | `SELECT * FROM sale_pay FOR UPDATE` | FOR UPDATE | 3 | 0B | statement contains forbidden keyword "UPDATE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| lck-02 | `SELECT * FROM sale_pay LOCK IN SHARE MODE` | LOCK IN SHARE MODE | 3 | 0B | statement contains forbidden phrase "LOCK IN SHARE MODE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| lck-03 | `SELECT * FROM sale_pay FOR SHARE` | FOR SHARE | 3 | 0B | statement contains forbidden phrase "FOR SHARE"; this tool only allows read-only queries | 12/2/11/0/0 ✔ | PASS |
| tab-01 | `TABLE sale_pay` | TABLE 语句（首 token 非白名单） | 3 | 0B | statement must start with one of SELECT, WITH, SHOW, DESC, DESCRIBE, EXPLAIN; got "TABLE" | 12/2/11/0/0 ✔ | PASS |
| tab-02 | `VALUES ROW(1)` | VALUES 语句 | 3 | 0B | statement must start with one of SELECT, WITH, SHOW, DESC, DESCRIBE, EXPLAIN; got "VALUES" | 12/2/11/0/0 ✔ | PASS |
| emp-01 | `(空字符串)` | 空语句 → empty statement | 3 | 0B | empty statement | 12/2/11/0/0 ✔ | PASS |
| emp-02 | `(纯空白)` | 纯空白语句 | 3 | 0B | empty statement | 12/2/11/0/0 ✔ | PASS |
| emp-03 | `;` | 仅分号 | 3 | 0B | empty statement | 12/2/11/0/0 ✔ | PASS |
| emp-04 | `;;` | 双分号 | 3 | 0B | empty statement | 12/2/11/0/0 ✔ | PASS |

### 6.1 黑名单关键字全覆盖（SPEC §6.2.5）

- 对 SPEC §6.2.5 列出的 **48 个**关键字逐个执行 `SELECT 1 AS x, <KEYWORD>`，要求 exit=3、stdout 空、stderr 含 `blocked`。
- 结果：`blocked=48/48 failures=`（48/48 全部拦截，结论 **PASS**）。关键字覆盖：INSERT/UPDATE/DELETE/REPLACE/MERGE/UPSERT/CREATE/ALTER/DROP/TRUNCATE/RENAME/GRANT/REVOKE/SET/RESET/CALL/DO/LOAD/IMPORT/HANDLER/FLUSH/KILL/SHUTDOWN/INSTALL/UNINSTALL/PREPARE/EXECUTE/DEALLOCATE/XA/START/BEGIN/COMMIT/ROLLBACK/SAVEPOINT/RELEASE/LOCK/UNLOCK/OPTIMIZE/ANALYZE/REPAIR/CHECKSUM/USE/INTO/OUTFILE/DUMPFILE/BACKUP/RESTORE/PURGE。

### 6.2 短语检查 / 拦截先于连库 / 超大语句 / 安全解析

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| phr-01 | 短语 `INTO OUTFILE` 被拦截（给出短语级原因） | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden phrase "INTO OUTFILE"; this tool only allows read-only q... | PASS |
| phr-02 | 短语 `INTO DUMPFILE` 被拦截 | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden phrase "INTO DUMPFILE"; this tool only allows read-only ... | PASS |
| phr-03 | 短语 `LOCK IN SHARE MODE` 被拦截 | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden phrase "LOCK IN SHARE MODE"; this tool only allows read-... | PASS |
| phr-04 | 短语 `FOR SHARE` 被拦截 | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden phrase "FOR SHARE"; this tool only allows read-only quer... | PASS |
| order-01 | guard 先于任何 DB 交互：不可达端口配置 + `DROP` → 仍 exit 3（而非连接错误 1） | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden keyword "DROP"; this tool only allows read-only queries \| | PASS |
| order-02 | guard 先于任何 DB 交互：错误密码配置 + `INSERT` → 仍 exit 3 | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden keyword "INSERT"; this tool only allows read-only querie... | PASS |
| sz-01 | 语句 > 64KB → exit 3（提示 70014 bytes / limit 65536），且不连库 | exit=3; stdout=0B; stderr: mysqlq: blocked: statement is too long (70007 bytes, limit 65536 bytes); split it into smaller queries... | PASS |
| parse-01 | 未闭合 `/*` 注释 → 无法安全解析，exit 3 | exit=3; stdout=0B; stderr: mysqlq: blocked: cannot safely parse statement: unterminated /* comment at line 1, column 10 \| | PASS |
| parse-02 | 语句中间的 `/*!50000 ... */` 版本注释 → exit 3 | exit=3; stdout=0B; stderr: mysqlq: blocked: cannot safely parse statement: versioned comment /*! ... */ is not allowed (MySQL exe... | PASS |

### 6.3 完整性总核对

| 核对项 | 期望 | 实际 | 结论 |
| --- | --- | --- | --- |
| 45 条拦截用例逐条后（mysqlq 查询） | tables=12 sale_pay=2 asr=11 spr=0 residue=0 | 45/45 全部符合 | PASS |
| 45 条拦截用例逐条后（独立 mysql 客户端交叉核对） | 12/2/11/0/0 | 45/45 全部 match | PASS |
| 全部验证结束后整体复核 | 同上 | 12/2/11/0/0（两客户端一致） | PASS |
| 残留表检测（zz_probe/sale_pay_bak/t_x/sale_pay_tmp/probe_tbl） | count=0 | 0 | PASS |
| 二进制 SHA256 前后一致 | 未变化 | 未变化（7C0A02C9122730BB...） | PASS |

## 7. 行数限制（硬性需求，SPEC §3 / §8.5）

验证结果集使用 `information_schema.COLUMNS` 全库查询（数千行），以 json 数组元素个数精确计数。

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| row-default | 默认上限 20 行；stderr 含 `truncated to 20 row(s)` | exit=0 rows=20; stderr: [mysqlq] 20 row(s) in 24ms \| [mysqlq] truncated to 20 row(s) (--max-rows) \| | PASS |
| row-max5 | `--max-rows 5` → 恰好 5 行；stderr 含 truncated to 5 | exit=0 rows=5; stderr: [mysqlq] 5 row(s) in 22ms \| [mysqlq] truncated to 5 row(s) (--max-rows) \| | PASS |
| row-max100 | `--max-rows 100` → 恰好 100 行；stderr 含 truncated to 100 | exit=0 rows=100; stderr: [mysqlq] 100 row(s) in 23ms \| [mysqlq] truncated to 100 row(s) (--max-rows) \| | PASS |
| row-config5 | 配置 `max_rows: 5` → 恰好 5 行 | exit=0 rows=5; stderr: [mysqlq] 5 row(s) in 22ms \| [mysqlq] truncated to 5 row(s) (--max-rows) \| | PASS |
| row-config500-clamp | 配置 `max_rows: 500` → 钳制 100 行；stderr 有 warning（原文 `max_rows 500 in config exceeds the hard limit 100, using 100`） | exit=0 rows=100; stderr: [mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100 \| [mysqlq] 100 row(s) in 23ms \| [mysqlq] ... | PASS |
| row-cli-over-config | `--max-rows 50` > 配置 500 → 50 行 | exit=0 rows=50; stderr: [mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100 \| [mysqlq] 50 row(s) in 25ms \| [mysqlq] t... | PASS |
| row-config500-cli100 | 配置 500 + `--max-rows 100` → 100 行（硬上限） | exit=0 rows=100; stderr: [mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100 \| [mysqlq] 100 row(s) in 26ms \| [mysqlq] ... | PASS |
| row-info5 | `info` 的 default_max_rows 反映配置（5） | exit=0; stdout=390B; stderr: [mysqlq] 10 row(s) in 0ms \| | PASS |
| row-info500 | `info` 的 default_max_rows 反映钳制结果（100）且 stderr 有 warning | exit=0; stdout=396B; stderr: [mysqlq] warning: max_rows 500 in config exceeds the hard limit 100, using 100 \| [mysqlq] 10 row(s) in 0ms \| | PASS |
| row-no-combo-over-100 | 任何 flag/config 组合都 ≤ 100 行 | max observed <= 100; default=20 | PASS |

`--max-rows 101` / `0` / `-1` 均按 SPEC exit 2（见 §4 退出码表）。结论：默认 20、`--max-rows` 5/100、config 5/500 钳制、组合优先级全部正确，**任何组合均未超过 100 行**。

## 8. 超时与错误质量（SPEC §6.3.4 / §8）

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| timeout-sleep | `SELECT SLEEP(5)` + `--timeout 1s` → exit 1，stderr 说明超时，stdout 为空，无 `[mysql]` 驱动日志，实际耗时约 1.0s | exit=1 stdout=0B ms=1037 stderr: mysqlq: error: query timed out after 1s (increase --timeout if the query is expected to be slow) \| | PASS |
| timeout-cartesian | 3 表笛卡尔积 + `--timeout 1s` → exit 1，同样干净 | exit=1 stdout=0B ms=1038 stderr: mysqlq: error: query timed out after 1s (increase --timeout if the query is expected to be slow) \| | PASS |

实测 stderr 原文：`mysqlq: error: query timed out after 1s (increase --timeout if the query is expected to be slow)`；stdout 字节数 0；stderr 中**没有** `[mysql]` 驱动内部日志（如 `packets.go`、`read tcp` 等），错误信息可读。

## 9. 防误伤 / 正例（SPEC §6.2.4 / §7）

只读白名单不能被“误伤”：字符串字面量、反引号标识符、注释中的关键字都不应触发拦截；合法只读语句必须正常执行。

| 用例 | 期望 | 实际（摘要） | 结论 |
| --- | --- | --- | --- |
| fp-01 | SELECT 中含字符串字面量 `DELETE FROM sale_pay` / `UPDATE ...` → 正常返回（字面量不参与关键字判断） | exit=0; stdout=116B; stderr: [mysqlq] 1 row(s) in 1ms \| | PASS |
| fp-02 | 反引号标识符 `` SELECT `id` FROM `sale_pay` `` → 正常返回 2 行 | exit=0; stdout=18B; stderr: [mysqlq] 2 row(s) in 0ms \| | PASS |
| fp-03 | 反引号别名含关键字 `` AS `insert` `` / `` AS `delete` `` → 正常 | exit=0; stdout=45B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-04 | `/*+ MAX_EXECUTION_TIME(1000) */` optimizer hint 允许（按普通注释跳过） | exit=0; stdout=29B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-05 | `EXPLAIN SELECT * FROM sale_pay` → 正常返回执行计划 | exit=0; stdout=308B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-06 | `SHOW TABLES` → 正常返回 12 行 | exit=0; stdout=213B; stderr: [mysqlq] 12 row(s) in 1ms \| | PASS |
| fp-07 | `DESC sale_pay` → 正常返回 18 行 | exit=0; stdout=1225B; stderr: [mysqlq] 18 row(s) in 2ms \| | PASS |
| fp-08 | `WITH ... SELECT` → 正常 | exit=0; stdout=23B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-09 | 末尾单个分号 `SELECT 1 AS a;` → 正常 | exit=0; stdout=6B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-10 | `SHOW CREATE TABLE` 被拦截（含 CREATE 关键字），且提示 `use "mysqlq ddl <table>"` | exit=3; stdout=0B; stderr: mysqlq: blocked: statement contains forbidden keyword "CREATE"; this tool only allows read-only queries (use "my... | PASS |
| fp-11 | `--` 终止符：之前的 `--format json` 生效，之后的 SQL 按位置参数处理（含 `-- note` 注释后 SELECT 正常） | exit=0; stdout=35B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |
| fp-12 | 仅注释的 SQL → 视为空语句拦截 exit 3 | exit=3; stdout=0B; stderr: mysqlq: blocked: empty statement \| | PASS |
| fp-13 | 纵深防御：查询内 `@@transaction_read_only`=1、`@@max_execution_time`=10000（服务端只读会话） | exit=0; stdout=42B; stderr: [mysqlq] 1 row(s) in 0ms \| | PASS |

### 9.1 纵深防御证据（SPEC §6.3）

- 会话只读：`--format json --timeout 10s query "SELECT @@transaction_read_only AS ro, @@max_execution_time AS met"` → `{"ro": 1, "met": 10000}`，证明工具在连接上执行了 `SET SESSION TRANSACTION READ ONLY` 并把超时下推为服务端 `max_execution_time`（降到“词法检查被绕过”时的第二道防线）。
- 拦截先于连库：`--config` 指向不可达端口/错误密码的配置再执行写语句，仍返回 exit 3（而非连接错误 1），证明 guard 在任何数据库交互之前完成（SPEC §6.2.7）。
- SQL 注入面交叉验证：将注入载荷作为**表名/keyword/库名**参数传入（`columns "sale_pay; DROP TABLE sale_pay"`、`find "a%' OR 1=1 -- "`、`--db "bbc'; DROP ..."` 等），均未执行写入（表名按字面量匹配报不存在 / MySQL 拒绝非法库名），表数、行数不变。

## 10. 发现的问题清单

### [BLOCKER]：无

未发现任何可绕过只读防护、写入数据、退出码错误、行数超限或密码泄露的问题。

### [MINOR-1] `columns` / `schema` 的 CSV 表头以 `#` 开头时，Windows PowerShell 的 `Import-Csv` / `ConvertFrom-Csv` 会把它当注释行跳过

- **现象**：`mysqlq --format csv columns sale_pay` 首行为 `#,COLUMN,TYPE,NULL,KEY,DEFAULT,EXTRA,COMMENT`（SPEC §3.4 规定列名 `#`）。PowerShell 的 `Import-Csv` / `ConvertFrom-Csv` 会忽略以 `#` 开头的行，导致表头错位（把首条数据当表头，18 行数据变 17 行）；`Import-Csv -Header <显式表头>` 才能正确读回。
- **判定**：CSV 输出本身**符合 RFC 4180**——用 Python 标准库 `csv` 解析：表头 `["#","COLUMN","TYPE","NULL","KEY","DEFAULT","EXTRA","COMMENT"]`、18 行数据，字段引号/CRLF 均正确。这是 PowerShell 解析器的非标准行为（把 `#` 行当注释），不是工具数据错误，也不影响 JSON/table/md 格式。
- **影响面**：仅影响 PowerShell 消费方用默认 `Import-Csv` 读取 `columns`/`schema` 两个命令的 CSV 输出；`mysqlq` 自身的 `--format json` 无此问题（推荐 agent 用 json）。
- **复现**：`mysqlq.exe --format csv columns sale_pay > cols.csv`；`Import-Csv .\cols.csv` 出现警告且表头错位；`Import-Csv .\cols.csv -Header ("#","COLUMN","TYPE","NULL","KEY","DEFAULT","EXTRA","COMMENT")` 正确。
- **建议（仅建议，验证者未改源码）**：CSV 输出时对以 `#` 开头的表头字段加引号（`"#"`），或在使用文档中提示 PowerShell 用户改用 json / 显式 `-Header`。

### 观察项（非缺陷，仅记录）

1. **`databases --all` 与默认 20 行上限的交互**：服务器共 21 个库（17 非系统 + 4 系统库），默认 `max_rows=20` 时 `--all` 会截掉最后一个（`sys`），stderr 有 `truncated to 20 row(s)` 提示。这是行数硬限制按规格工作，需要完整列表时用 `--max-rows 100`。
2. **`version` 忽略 `--format`**：`--format json/csv/md version` 仍输出纯文本 `mysqlq 1.0.0`。SPEC §3.10 未规定 version 的格式行为，且行为稳定、exit 0，不视为缺陷。
3. **`SHOW CREATE TABLE` 被只读黑名单拦截**：符合 SPEC §6.2.5（CREATE 关键字），且错误信息正确提示改用 `mysqlq ddl <table>`（符合 §9 的预期指引）。

## 11. 历史 FAIL 用例的处理（均为 harness 缺陷，工具无问题）

首次运行出现 5 条 FAIL，经逐条复核确认全部是验证脚本自身的期望/调用方式错误，并非工具缺陷；已修正脚本后重跑，最终状态如下：

| 用例 | 首次 FAIL 原因 | 修正方式 | 重跑结果 |
| --- | --- | --- | --- |
| commands/cmd-02b、formats/info-json-noleak | 假阳性：用 `root` 当密码标记，但 info 合法显示 `user: root`（密码与用户名同为 root） | 改为哨兵密码（`S3cr3tLeak_9z` 不可达端口、`LeakMarker_9z` 错误密码/MYSQLQ_PASSWORD），并断言无 `root:root`/`@tcp(`/`db_passwd:` 等凭证模式；密码等于用户名时跳过该标记 | PASS |
| formats/ddl-table2 | 期望错误：误要求 ddl 的 table 格式有 `----` 表头分隔 | 按 SPEC §3.6 改为断言“原始多行 DDL、无表头/分隔线、以 CREATE TABLE 开头”（并补上遗漏的表名参数） | PASS |
| config/cfg-db-flag | 期望错误：用默认 20 行上限断言 `information_schema` 中排第 68 位的 `TABLES` | 增加 `--max-rows 100` 后再断言 | PASS |
| config/cfg-env-port | 调用方式错误：日志中命令为 bash 语法 `MYSQLQ_PORT=3399 mysqlq info`，PS 把它当未知命令 → exit 2 | 改用 `EnvironmentVariables` 注入 `MYSQLQ_PORT=3399` 后调用（实测 exit 1，信息含 `127.0.0.1:3399`） | PASS |

> 说明：上述 5 条均已纳入 `scripts/verify/verify.ps1` 的回归用例，重跑后全部 PASS；同时按“每个用例只断言一件事”的原则拆分了 exit code 与格式形状断言。

## 12. 交付结论

- **总体结论：可交付（PASS）**。
- 规格 §8 验收标准逐项满足：`bin\mysqlq.exe` 可用；`info` 正确显示 8.0.33/bbc 且不泄露密码；全部命令正常、四种格式合法；§7 拦截矩阵逐条 exit 3 且数据零变化；行数限制（默认 20、config 5、config 500→100 钳制、`--max-rows 101`→exit 2、任何组合 ≤100）全部满足；`--help` 可用、未知命令 exit 2。
- 唯一遗留为 **[MINOR] CSV 的 `#` 表头在 PowerShell `Import-Csv` 下的互操作提示**（数据本身 RFC4180 合法），不影响交付判定，建议后续迭代或在使用文档中提示。
- 未发现 [BLOCKER]。本次验证未修改任何源码、配置与文档（除本报告与 `scripts/verify/**`）。

## 13. 复现与证据文件

```
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify\verify.ps1
```

- `scripts/verify/verify.ps1`：可重复执行的完整验证脚本（纯 ASCII，Windows PowerShell 5.1 兼容；不写数据库，只读）。
- `scripts/verify/last-run.log` / `scripts/verify/last-run.md`：最近一次运行的 326 例逐条原始证据（命令 / 期望 / 实际 / 结论）。

---

*本报告由独立验证者根据真实库黑盒实测生成；报告内所有"实际"值均取自 `scripts/verify/last-run.log`。*
