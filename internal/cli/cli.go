// Package cli 实现 mysqlq 的命令行解析、子命令分发与退出码。
package cli

import (
	"context"
	"fmt"
	"io"
	"strconv"
	"strings"
	"time"

	"mysql-query-cli/internal/config"
	"mysql-query-cli/internal/db"
	"mysql-query-cli/internal/guard"
	"mysql-query-cli/internal/output"
)

// Version 是工具版本号（`version` 命令与 `info` 都会用到）。
const Version = "1.0.0"

// DefaultTimeout 是查询默认超时（SPEC §3）。
const DefaultTimeout = 30 * time.Second

// usageError 表示用法错误（退出码 2）。
type usageError struct{ msg string }

func (e *usageError) Error() string { return e.msg }

func usageErrorf(format string, args ...any) error {
	return &usageError{msg: fmt.Sprintf(format, args...)}
}

// options 是解析后的命令行选项。
type options struct {
	configPath string
	dbOverride string
	format     output.Format
	timeout    time.Duration
	maxRows    int
	maxRowsSet bool
	all        bool
	help       bool
	command    string
	args       []string
}

// Execute 是 CLI 入口：返回进程退出码（0 成功 / 1 运行时 / 2 用法 / 3 拦截）。
func Execute(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	o, err := parseArgs(args)
	if err != nil {
		fmt.Fprintf(stderr, "mysqlq: usage: %s\n", err.Error())
		return 2
	}
	if o.help {
		printUsage(stdout)
		return 0
	}
	if o.command == "" {
		printUsage(stdout) // 缺命令：用法错误，但按 SPEC 打印到 stdout
		return 2
	}
	if err := validateCommand(o); err != nil {
		fmt.Fprintf(stderr, "mysqlq: usage: %s\n", err.Error())
		return 2
	}

	// version / help 不需要配置，也不连库。
	switch o.command {
	case "version":
		fmt.Fprintf(stdout, "mysqlq %s\n", Version)
		return 0
	case "help":
		printUsage(stdout)
		return 0
	}

	// ---- query：先做只读拦截，拦截必须早于任何与数据库的交互（SPEC §6.2-7） ----
	var querySQL string
	if o.command == "query" {
		querySQL, err = readQuery(o, stdin)
		if err != nil {
			fmt.Fprintf(stderr, "mysqlq: usage: %s\n", err.Error())
			return 2
		}
		if err := guard.Check(querySQL); err != nil {
			fmt.Fprintf(stderr, "mysqlq: blocked: %s\n", err.Error())
			return 3
		}
	}

	// ---- 配置 ----
	cfg, err := config.Load(o.configPath, o.dbOverride)
	if err != nil {
		fmt.Fprintf(stderr, "mysqlq: config: %s\n", err.Error())
		return 1
	}
	for _, w := range cfg.Warnings {
		fmt.Fprintf(stderr, "[mysqlq] warning: %s\n", w)
	}

	// 生效行数上限：--max-rows > config max_rows > 20，且任何情况下 <= 100。
	maxRows := cfg.MaxRows
	if o.maxRowsSet {
		maxRows = o.maxRows
	}
	if maxRows > config.HardMaxRows {
		maxRows = config.HardMaxRows
	}
	if maxRows < 1 {
		maxRows = config.DefaultMaxRows
	}

	ctx := context.Background()
	database, err := db.Open(ctx, *cfg, o.timeout)
	if err != nil {
		fmt.Fprintf(stderr, "mysqlq: error: %s\n", err.Error())
		return 1
	}
	defer func() { _ = database.Close() }()
	for _, w := range database.Warnings {
		fmt.Fprintf(stderr, "[mysqlq] warning: %s\n", w)
	}

	a := &app{
		opts:    o,
		cfg:     cfg,
		db:      database,
		stdout:  stdout,
		stderr:  stderr,
		maxRows: maxRows,
		format:  o.format,
	}
	if err := a.run(ctx, querySQL); err != nil {
		fmt.Fprintf(stderr, "mysqlq: error: %s\n", err.Error())
		return 1
	}
	return 0
}

// app 汇集一次命令执行所需的依赖。
type app struct {
	opts    *options
	cfg     *config.Config
	db      *db.DB
	stdout  io.Writer
	stderr  io.Writer
	maxRows int
	format  output.Format
}

// run 分发子命令。
func (a *app) run(ctx context.Context, querySQL string) error {
	switch a.opts.command {
	case "info":
		return a.cmdInfo(ctx)
	case "databases", "dbs":
		return a.cmdDatabases(ctx)
	case "tables":
		return a.cmdTables(ctx)
	case "columns":
		return a.cmdColumns(ctx)
	case "indexes":
		return a.cmdIndexes(ctx)
	case "ddl":
		return a.cmdDDL(ctx)
	case "schema":
		return a.cmdSchema(ctx)
	case "query":
		return a.cmdQuery(ctx, querySQL)
	case "find":
		return a.cmdFind(ctx)
	default:
		return fmt.Errorf("unknown command %q", a.opts.command)
	}
}

// ---------- 各子命令 ----------

func (a *app) cmdInfo(ctx context.Context) error {
	start := time.Now()
	serverVersion, err := a.db.ServerVersion(ctx)
	if err != nil {
		return err
	}
	rs := db.NewResultSet(db.TextCol("KEY"), db.TextCol("VALUE"))
	rs.Add("tool_version", Version)
	rs.Add("config_file", a.cfg.Source)
	rs.Add("host", a.cfg.Host)
	rs.Add("port", strconv.Itoa(a.cfg.Port))
	rs.Add("database", a.cfg.Name)
	rs.Add("user", a.cfg.User) // 密码永不输出
	rs.Add("server_version", serverVersion)
	rs.Add("read_only", "true") // 本工具强制只读（会话 + 事务双重）
	rs.Add("default_max_rows", strconv.Itoa(a.maxRows))
	rs.Add("default_timeout", a.opts.timeout.String())
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.stats(len(rs.Rows), time.Since(start))
	return nil
}

func (a *app) cmdDatabases(ctx context.Context) error {
	start := time.Now()
	rs, err := a.db.Databases(ctx, a.opts.all, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

func (a *app) cmdTables(ctx context.Context) error {
	start := time.Now()
	rs, err := a.db.Tables(ctx, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

func (a *app) cmdColumns(ctx context.Context) error {
	table := a.opts.args[0]
	start := time.Now()
	rs, err := a.db.Columns(ctx, table, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

func (a *app) cmdIndexes(ctx context.Context) error {
	table := a.opts.args[0]
	start := time.Now()
	rs, err := a.db.Indexes(ctx, table, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

func (a *app) cmdDDL(ctx context.Context) error {
	table := a.opts.args[0]
	start := time.Now()
	ddl, err := a.db.ShowCreateTable(ctx, table)
	if err != nil {
		return err
	}
	if a.format == output.Table {
		// table 格式：直接输出 SHOW CREATE TABLE 第二列原文（多行，不做对齐）。
		if _, err := fmt.Fprintln(a.stdout, ddl); err != nil {
			return err
		}
	} else {
		rs := db.NewResultSet(db.TextCol("TABLE"), db.TextCol("DDL"))
		rs.Add(table, ddl)
		if err := output.Render(a.stdout, rs, a.format); err != nil {
			return err
		}
	}
	a.stats(1, time.Since(start))
	return nil
}

func (a *app) cmdSchema(ctx context.Context) error {
	table := a.opts.args[0]

	t0 := time.Now()
	columns, err := a.db.Columns(ctx, table, a.maxRows)
	if err != nil {
		return err
	}
	colsElapsed := time.Since(t0)

	t1 := time.Now()
	indexes, err := a.db.Indexes(ctx, table, a.maxRows)
	if err != nil {
		return err
	}
	idxElapsed := time.Since(t1)

	t2 := time.Now()
	ddl, err := a.db.ShowCreateTable(ctx, table)
	if err != nil {
		return err
	}
	ddlElapsed := time.Since(t2)

	switch a.format {
	case output.JSON:
		if err := output.RenderSchemaJSON(a.stdout, a.cfg.Name, table, columns, indexes, ddl); err != nil {
			return err
		}
	case output.Table:
		// 三段视图，段标题打印到 stdout。
		if _, err := fmt.Fprintln(a.stdout, "== columns =="); err != nil {
			return err
		}
		if err := output.Render(a.stdout, columns, a.format); err != nil {
			return err
		}
		if _, err := fmt.Fprintln(a.stdout, "\n== indexes =="); err != nil {
			return err
		}
		if err := output.Render(a.stdout, indexes, a.format); err != nil {
			return err
		}
		if _, err := fmt.Fprintln(a.stdout, "\n== ddl =="); err != nil {
			return err
		}
		if _, err := fmt.Fprintln(a.stdout, ddl); err != nil {
			return err
		}
	case output.CSV:
		// csv/md 没有"多段"的天然表示：每段各自带表头，段之间用空行分隔。
		if err := output.Render(a.stdout, columns, a.format); err != nil {
			return err
		}
		if err := a.blankLine("\r\n"); err != nil {
			return err
		}
		if err := output.Render(a.stdout, indexes, a.format); err != nil {
			return err
		}
		if err := a.blankLine("\r\n"); err != nil {
			return err
		}
		ddlRS := db.NewResultSet(db.TextCol("TABLE"), db.TextCol("DDL"))
		ddlRS.Add(table, ddl)
		if err := output.Render(a.stdout, ddlRS, a.format); err != nil {
			return err
		}
	default: // Markdown
		if err := output.Render(a.stdout, columns, a.format); err != nil {
			return err
		}
		if err := a.blankLine("\n"); err != nil {
			return err
		}
		if err := output.Render(a.stdout, indexes, a.format); err != nil {
			return err
		}
		if err := a.blankLine("\n"); err != nil {
			return err
		}
		ddlRS := db.NewResultSet(db.TextCol("TABLE"), db.TextCol("DDL"))
		ddlRS.Add(table, ddl)
		if err := output.Render(a.stdout, ddlRS, a.format); err != nil {
			return err
		}
	}

	a.statsResult(columns, colsElapsed)
	a.statsResult(indexes, idxElapsed)
	a.stats(1, ddlElapsed)
	return nil
}

func (a *app) cmdQuery(ctx context.Context, querySQL string) error {
	start := time.Now()
	rs, err := a.db.Query(ctx, querySQL, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

func (a *app) cmdFind(ctx context.Context) error {
	keyword := a.opts.args[0]
	start := time.Now()
	rs, err := a.db.Find(ctx, keyword, a.maxRows)
	if err != nil {
		return err
	}
	if err := output.Render(a.stdout, rs, a.format); err != nil {
		return err
	}
	a.statsResult(rs, time.Since(start))
	return nil
}

// ---------- 辅助 ----------

func (a *app) blankLine(sep string) error {
	_, err := io.WriteString(a.stdout, sep)
	return err
}

// stats 把行数统计写到 stderr（stdout 只放数据，SPEC §4）。
func (a *app) stats(rows int, elapsed time.Duration) {
	fmt.Fprintf(a.stderr, "[mysqlq] %d row(s) in %s\n", rows, durString(elapsed))
}

// statsResult 输出行数统计，并在结果被行数上限截断时给出提示。
func (a *app) statsResult(rs *db.ResultSet, elapsed time.Duration) {
	a.stats(len(rs.Rows), elapsed)
	if rs.Truncated {
		fmt.Fprintf(a.stderr, "[mysqlq] truncated to %d row(s) (--max-rows)\n", a.maxRows)
	}
}

func durString(d time.Duration) string {
	if d < time.Millisecond {
		return "0ms"
	}
	return d.Round(time.Millisecond).String()
}

// readQuery 从参数或 stdin 读取 SQL。
func readQuery(o *options, stdin io.Reader) (string, error) {
	arg := o.args[0]
	if arg != "-" {
		return arg, nil
	}
	data, err := io.ReadAll(stdin)
	if err != nil {
		return "", fmt.Errorf("cannot read SQL from stdin: %v", err)
	}
	sql := string(data)
	if strings.TrimSpace(sql) == "" {
		return "", fmt.Errorf("stdin contained no SQL text (expected a read-only statement)")
	}
	return sql, nil
}

// ---------- 参数解析 ----------

// parseArgs 解析全局参数与子命令。参数可以出现在子命令前后；`--` 之后全部当作位置参数。
func parseArgs(args []string) (*options, error) {
	o := &options{
		format:  output.Table,
		timeout: DefaultTimeout,
	}
	var positional []string
	terminated := false
	i := 0

	nextValue := func(flag string) (string, error) {
		if i+1 >= len(args) {
			return "", usageErrorf("flag %s requires a value", flag)
		}
		i++
		return args[i], nil
	}

	for ; i < len(args); i++ {
		arg := args[i]
		if terminated || arg == "-" || !strings.HasPrefix(arg, "-") {
			positional = append(positional, arg)
			continue
		}
		if arg == "--" {
			terminated = true
			continue
		}

		name, inlineValue, hasInlineValue := arg, "", false
		if idx := strings.Index(arg, "="); idx > 0 {
			name, inlineValue, hasInlineValue = arg[:idx], arg[idx+1:], true
		}
		value := func() (string, error) {
			if hasInlineValue {
				return inlineValue, nil
			}
			return nextValue(name)
		}

		switch name {
		case "-c", "--config":
			v, err := value()
			if err != nil {
				return nil, err
			}
			o.configPath = v
		case "--db":
			v, err := value()
			if err != nil {
				return nil, err
			}
			o.dbOverride = v
		case "--format":
			v, err := value()
			if err != nil {
				return nil, err
			}
			f, ok := output.Parse(v)
			if !ok {
				return nil, usageErrorf("invalid --format %q: expected one of table, json, csv, md", v)
			}
			o.format = f
		case "--timeout":
			v, err := value()
			if err != nil {
				return nil, err
			}
			d, perr := time.ParseDuration(v)
			if perr != nil || d <= 0 {
				return nil, usageErrorf("invalid --timeout %q: expected a positive duration like 10s, 500ms, 2m", v)
			}
			o.timeout = d
		case "--max-rows":
			v, err := value()
			if err != nil {
				return nil, err
			}
			n, perr := strconv.Atoi(v)
			if perr != nil {
				return nil, usageErrorf("invalid --max-rows %q: expected an integer between 1 and %d", v, config.HardMaxRows)
			}
			if n < 1 || n > config.HardMaxRows {
				return nil, usageErrorf("--max-rows must be between 1 and %d (got %d)", config.HardMaxRows, n)
			}
			o.maxRows = n
			o.maxRowsSet = true
		case "-h", "--help":
			o.help = true
		case "--all":
			o.all = true
		default:
			return nil, usageErrorf("unknown flag %q (run \"mysqlq --help\")", arg)
		}
	}

	if o.help {
		return o, nil
	}
	if len(positional) == 0 {
		return o, nil
	}
	o.command = positional[0]
	o.args = positional[1:]
	return o, nil
}

// validateCommand 在连库之前校验命令与参数数量。
func validateCommand(o *options) error {
	switch o.command {
	case "info", "databases", "dbs", "tables", "columns", "indexes", "ddl",
		"schema", "query", "find", "version", "help":
	default:
		return usageErrorf("unknown command %q (commands: info, databases, tables, columns, indexes, ddl, schema, query, find, version)", o.command)
	}

	needOne := map[string]bool{
		"columns": true, "indexes": true, "ddl": true, "schema": true, "query": true, "find": true,
	}
	if needOne[o.command] {
		if len(o.args) != 1 {
			return usageErrorf("%s requires exactly 1 argument, got %d (run \"mysqlq --help\")", o.command, len(o.args))
		}
		return nil
	}
	if len(o.args) != 0 {
		return usageErrorf("%s takes no arguments, got %d", o.command, len(o.args))
	}
	return nil
}
