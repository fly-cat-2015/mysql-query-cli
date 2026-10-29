// Package db 负责与 MySQL 的连接、只读会话/事务、查询执行与元数据查询。
//
// 纵深防御（SPEC §6.3）：
//  1. 连接串固定 multiStatements=false、interpolateParams=false、读写超时；
//  2. 单连接单会话，会话级 READ ONLY + 事务级 ReadOnly 双重只读；
//  3. context 超时 + 会话 max_execution_time；
//  4. 逐行扫描，达到行数上限立即停止读取。
package db

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/go-sql-driver/mysql"

	"mysql-query-cli/internal/config"
)

// discardLogger 丢弃 go-sql-driver/mysql 的内部日志。
// 驱动默认把 `[mysql] ... packets.go` 这类日志直接写到 os.Stderr，既噪音又不可操作；
// 所有失败都会通过 error 转成可读信息，因此这里静默。
type discardLogger struct{}

func (discardLogger) Print(v ...any) {}

// Column 是结果集的一列。
type Column struct {
	Name string
	// Numeric 表示该列是数值类型：table 格式右对齐，json 格式输出为数字。
	Numeric bool
}

// Cell 是一个单元格。Null 为 true 时 Val 无意义。
type Cell struct {
	Null bool
	Val  string
}

// ResultSet 是一次查询的结果（已按行数上限截断）。
type ResultSet struct {
	Columns   []Column
	Rows      [][]Cell
	Truncated bool
	Elapsed   time.Duration
}

// NewResultSet 构造一个空结果集（用于本地组装的元数据结果）。
func NewResultSet(cols ...Column) *ResultSet {
	return &ResultSet{Columns: cols}
}

// TextCol 返回文本列。
func TextCol(name string) Column { return Column{Name: name} }

// NumCol 返回数值列。
func NumCol(name string) Column { return Column{Name: name, Numeric: true} }

// Add 追加一行；nil 表示 SQL NULL。
func (rs *ResultSet) Add(vals ...any) {
	row := make([]Cell, len(vals))
	for i, v := range vals {
		switch x := v.(type) {
		case nil:
			row[i] = Cell{Null: true}
		case string:
			row[i] = Cell{Val: x}
		case []byte:
			row[i] = Cell{Val: string(x)}
		case int:
			row[i] = Cell{Val: strconv.Itoa(x)}
		case int64:
			row[i] = Cell{Val: strconv.FormatInt(x, 10)}
		case bool:
			row[i] = Cell{Val: strconv.FormatBool(x)}
		default:
			row[i] = Cell{Val: fmt.Sprint(x)}
		}
	}
	rs.Rows = append(rs.Rows, row)
}

// DB 是 mysqlq 使用的单连接数据库句柄。
type DB struct {
	sqlDB   *sql.DB
	conn    *sql.Conn
	cfg     config.Config
	addr    string
	timeout time.Duration

	// sessionReadOnly 表示 `SET SESSION TRANSACTION READ ONLY` 是否生效。
	sessionReadOnly bool
	// Warnings 是连接/会话建立期间的降级警告（由 CLI 打到 stderr）。
	Warnings []string
}

// Open 建立单连接、配置只读会话并返回 *DB。
func Open(ctx context.Context, cfg config.Config, timeout time.Duration) (*DB, error) {
	addr := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))

	mycfg := mysql.NewConfig()
	mycfg.User = cfg.User
	mycfg.Passwd = cfg.Passwd // 只在内存里使用，绝不会出现在任何输出/错误中
	mycfg.Net = "tcp"
	mycfg.Addr = addr
	mycfg.DBName = cfg.Name
	mycfg.MultiStatements = false   // 禁止多语句（纵深防御）
	mycfg.InterpolateParams = false // 使用服务端 prepare，避免客户端拼接
	mycfg.ParseTime = false         // 保持原始字符串，输出层按需处理
	mycfg.Loc = time.UTC
	mycfg.Timeout = timeout // 连接（dial）超时
	// 驱动 I/O 超时比查询超时多留 5s 余量：让 context 的超时先触发，
	// 这样用户看到的是可操作的 "query timed out after ..." 而不是驱动的
	// "invalid connection" 噪音。
	mycfg.ReadTimeout = timeout + 5*time.Second
	mycfg.WriteTimeout = timeout + 5*time.Second
	mycfg.Params = map[string]string{"charset": cfg.Charset}

	// 驱动内部的 `[mysql] ... packets.go` 日志直接写 os.Stderr，会污染 stderr、
	// 甚至在极端情况下混进期望"只有一行可操作信息"的输出。这里统一丢弃：
	// 所有失败都会通过返回的 error 转成可操作信息。
	mysql.SetLogger(discardLogger{})

	sqlDB, err := sql.Open("mysql", mycfg.FormatDSN())
	if err != nil {
		return nil, fmt.Errorf("cannot initialize MySQL driver: %w", err)
	}
	// 一条连接、用完即关：避免只读会话设置被其它连接绕过。
	sqlDB.SetMaxOpenConns(1)
	sqlDB.SetMaxIdleConns(1)
	sqlDB.SetConnMaxLifetime(0)

	d := &DB{sqlDB: sqlDB, cfg: cfg, addr: addr, timeout: timeout}

	conn, err := sqlDB.Conn(ctx)
	if err != nil {
		_ = sqlDB.Close()
		return nil, d.wrapConnectError(err)
	}
	d.conn = conn

	// 会话级只读（失败不报错、不退出，只用事务级只读兜底）。
	if _, err := conn.ExecContext(ctx, "SET SESSION TRANSACTION READ ONLY"); err != nil {
		d.Warnings = append(d.Warnings,
			fmt.Sprintf("could not enable session-level read-only mode (%v); falling back to per-transaction READ ONLY", err))
	} else {
		d.sessionReadOnly = true
	}
	// 服务端执行时间上限（失败忽略：客户端 context 超时仍然生效）。
	ms := timeout.Milliseconds()
	if ms < 1 {
		ms = 1
	}
	if _, err := conn.ExecContext(ctx, fmt.Sprintf("SET SESSION max_execution_time = %d", ms)); err != nil {
		d.Warnings = append(d.Warnings,
			fmt.Sprintf("could not set session max_execution_time (%v); client-side timeout is still enforced", err))
	}
	return d, nil
}

// Close 关闭连接。
func (d *DB) Close() error {
	var err error
	if d.conn != nil {
		err = d.conn.Close()
	}
	if e := d.sqlDB.Close(); err == nil {
		err = e
	}
	return err
}

// SessionReadOnly 报告会话级只读是否生效。
func (d *DB) SessionReadOnly() bool { return d.sessionReadOnly }

// Config 返回连接使用的配置（只读用途，不会打印密码）。
func (d *DB) Config() config.Config { return d.cfg }

// Query 在只读事务中执行一条无参数 SQL，最多返回 maxRows 行（超过则截断）。
func (d *DB) Query(ctx context.Context, query string, maxRows int) (*ResultSet, error) {
	return d.QueryArgs(ctx, query, maxRows)
}

// QueryArgs 在只读事务中执行 SQL；args 通过服务端 prepare 绑定，不做客户端字符串拼接。
func (d *DB) QueryArgs(ctx context.Context, query string, maxRows int, args ...any) (*ResultSet, error) {
	if maxRows < 1 {
		maxRows = 1
	}
	if maxRows > config.HardMaxRows {
		maxRows = config.HardMaxRows
	}
	ctx, cancel := context.WithTimeout(ctx, d.timeout)
	defer cancel()

	start := time.Now()
	// 事务级只读：即使词法拦截被绕过，MySQL 也会拒绝写入。
	tx, err := d.conn.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, d.wrap(ctxErr)
		}
		return nil, d.wrap(err)
	}
	rs, err := runQuery(ctx, tx, query, maxRows, args...)
	if err != nil {
		_ = tx.Rollback()
		// context 到期优先：驱动可能先报 "invalid connection" 之类的底层错误，
		// 但对用户来说真正的原因就是超时。
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, d.wrap(ctxErr)
		}
		return nil, d.wrap(err)
	}
	// 只读事务没有任何副作用，结束时回滚即可。
	if err := tx.Rollback(); err != nil {
		d.Warnings = append(d.Warnings, "rolling back read-only transaction failed: "+err.Error())
	}
	rs.Elapsed = time.Since(start)
	if len(rs.Columns) == 0 {
		return nil, errors.New("statement returned no result set (only SELECT/SHOW/DESC/DESCRIBE/EXPLAIN are supported)")
	}
	return rs, nil
}

// Scalar 执行一条返回单个值的 SQL（用于 info 等）。
func (d *DB) Scalar(ctx context.Context, query string) (string, error) {
	return d.ScalarArgs(ctx, query)
}

// ScalarArgs 是带参数版 Scalar。
func (d *DB) ScalarArgs(ctx context.Context, query string, args ...any) (string, error) {
	rs, err := d.QueryArgs(ctx, query, 1, args...)
	if err != nil {
		return "", err
	}
	if len(rs.Rows) == 0 || len(rs.Rows[0]) == 0 || rs.Rows[0][0].Null {
		return "", fmt.Errorf("query %q returned no value", query)
	}
	return rs.Rows[0][0].Val, nil
}

// runQuery 执行查询并逐行扫描，达到上限立刻停止读取（不把整表拉进内存）。
func runQuery(ctx context.Context, tx *sql.Tx, query string, maxRows int, args ...any) (*ResultSet, error) {
	rows, err := tx.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	names, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	colTypes, err := rows.ColumnTypes()
	if err != nil {
		return nil, err
	}
	rs := &ResultSet{Columns: make([]Column, len(names))}
	for i, name := range names {
		num := false
		if colTypes != nil && i < len(colTypes) {
			num = isNumericType(colTypes[i].DatabaseTypeName())
		}
		rs.Columns[i] = Column{Name: name, Numeric: num}
	}

	vals := make([]any, len(names))
	ptrs := make([]any, len(names))
	for i := range vals {
		ptrs[i] = &vals[i]
	}

	for rows.Next() {
		if len(rs.Rows) >= maxRows {
			// 已经取到上限，再多一行即说明被截断；立即停止读取。
			rs.Truncated = true
			break
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		row := make([]Cell, len(names))
		for i, v := range vals {
			row[i] = cellFromDriver(v)
		}
		rs.Rows = append(rs.Rows, row)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return rs, nil
}

func cellFromDriver(v any) Cell {
	switch x := v.(type) {
	case nil:
		return Cell{Null: true}
	case []byte:
		return Cell{Val: string(x)}
	case string:
		return Cell{Val: x}
	case int64:
		return Cell{Val: strconv.FormatInt(x, 10)}
	case uint64:
		return Cell{Val: strconv.FormatUint(x, 10)}
	case float64:
		return Cell{Val: strconv.FormatFloat(x, 'g', -1, 64)}
	case float32:
		return Cell{Val: strconv.FormatFloat(float64(x), 'g', -1, 32)}
	case bool:
		return Cell{Val: strconv.FormatBool(x)}
	case time.Time:
		return Cell{Val: x.Format("2006-01-02 15:04:05")}
	default:
		return Cell{Val: fmt.Sprint(x)}
	}
}

// numericTypes 是输出为 JSON 数字的类型集合（SPEC §4.2）。
var numericTypes = map[string]bool{
	"TINYINT": true, "SMALLINT": true, "MEDIUMINT": true,
	"INT": true, "INTEGER": true, "BIGINT": true,
	"DECIMAL": true, "NUMERIC": true, "DEC": true, "FIXED": true,
	"FLOAT": true, "DOUBLE": true, "REAL": true,
	"YEAR": true,
}

func isNumericType(dbType string) bool {
	t := strings.ToUpper(strings.TrimSpace(dbType))
	t = strings.TrimPrefix(t, "UNSIGNED ")
	return numericTypes[t]
}

// wrap 把底层错误转换成可操作的错误信息。
func (d *DB) wrap(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("query timed out after %s (increase --timeout if the query is expected to be slow)", d.timeout)
	}
	if errors.Is(err, context.Canceled) {
		return errors.New("query was canceled")
	}
	var me *mysql.MySQLError
	if errors.As(err, &me) {
		return d.wrapMySQLError(me)
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return fmt.Errorf("cannot communicate with MySQL at %s: %v (check db_host/db_port in the config and that the server is running)", d.addr, err)
	}
	return err
}

func (d *DB) wrapMySQLError(me *mysql.MySQLError) error {
	switch me.Number {
	case 1045: // ER_ACCESS_DENIED_ERROR
		return fmt.Errorf("access denied for user %q at %s (check db_user/db_passwd in the config file)", d.cfg.User, d.addr)
	case 1044: // ER_DBACCESS_DENIED_ERROR
		return fmt.Errorf("access denied to database %q for user %q (check db_user privileges)", d.cfg.Name, d.cfg.User)
	case 1049: // ER_BAD_DB_ERROR
		return fmt.Errorf("database %q does not exist (check --db or db_name in the config file; list databases with \"mysqlq databases\")", d.cfg.Name)
	case 1146: // ER_NO_SUCH_TABLE
		return fmt.Errorf("table does not exist: %s (list tables with \"mysqlq tables\")", me.Message)
	case 1142: // ER_TABLEACCESS_DENIED_ERROR
		return fmt.Errorf("permission denied: %s", me.Message)
	case 3024: // ER_QUERY_TIMEOUT
		return fmt.Errorf("query exceeded the server max_execution_time of %s (increase --timeout)", d.timeout)
	default:
		return fmt.Errorf("MySQL error %d: %s", me.Number, me.Message)
	}
}

// wrapConnectError 为连接失败补充可操作提示。
func (d *DB) wrapConnectError(err error) error {
	var me *mysql.MySQLError
	if errors.As(err, &me) {
		return d.wrapMySQLError(me)
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("connecting to MySQL at %s timed out after %s (check db_host/db_port and that the server is running)", d.addr, d.timeout)
	}
	var ne net.Error
	if errors.As(err, &ne) {
		return fmt.Errorf("cannot connect to MySQL at %s: %v (check db_host/db_port in the config file and that the MySQL server is running)", d.addr, err)
	}
	return fmt.Errorf("cannot connect to MySQL at %s: %v", d.addr, err)
}
