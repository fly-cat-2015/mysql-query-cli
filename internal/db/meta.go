package db

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/go-sql-driver/mysql"
)

// quoteIdent 用反引号包裹标识符（内部反引号双写），用于 SHOW CREATE TABLE 这类
// 不支持参数的语句。表名来自命令行，必须安全拼接。
func quoteIdent(s string) string {
	return "`" + strings.ReplaceAll(s, "`", "``") + "`"
}

// IsTableNotFound 判断错误是否为 MySQL 的 1146（表不存在）。
func IsTableNotFound(err error) bool {
	var me *mysql.MySQLError
	return errors.As(err, &me) && me.Number == 1146
}

// tableNotFound 返回可操作的表不存在错误。
func (d *DB) tableNotFound(table string) error {
	return fmt.Errorf("table %q does not exist in database %q (list tables with \"mysqlq tables\")", table, d.cfg.Name)
}

// ServerVersion 返回 MySQL 服务器版本（如 8.0.33）。
func (d *DB) ServerVersion(ctx context.Context) (string, error) {
	return d.Scalar(ctx, "SELECT VERSION()")
}

// Databases 列出数据库；includeSystem=false 时排除系统库。
func (d *DB) Databases(ctx context.Context, includeSystem bool, maxRows int) (*ResultSet, error) {
	q := "SELECT SCHEMA_NAME AS `DATABASE`, DEFAULT_CHARACTER_SET_NAME AS CHARSET, " +
		"DEFAULT_COLLATION_NAME AS COLLATION FROM information_schema.SCHEMATA"
	if !includeSystem {
		q += " WHERE SCHEMA_NAME NOT IN ('information_schema','mysql','performance_schema','sys')"
	}
	q += " ORDER BY SCHEMA_NAME"
	return d.Query(ctx, q, maxRows)
}

// Tables 列出当前库的表/视图。
func (d *DB) Tables(ctx context.Context, maxRows int) (*ResultSet, error) {
	q := "SELECT TABLE_NAME AS `TABLE`, TABLE_TYPE AS `TYPE`, ENGINE, " +
		"TABLE_ROWS AS `ROWS`, TABLE_COMMENT AS `COMMENT` " +
		"FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? ORDER BY TABLE_NAME"
	return d.QueryArgs(ctx, q, maxRows, d.cfg.Name)
}

// Columns 返回表的列结构；表不存在时返回可操作的错误。
func (d *DB) Columns(ctx context.Context, table string, maxRows int) (*ResultSet, error) {
	q := "SELECT ORDINAL_POSITION AS `#`, COLUMN_NAME AS `COLUMN`, COLUMN_TYPE AS `TYPE`, " +
		"IS_NULLABLE AS `NULL`, COLUMN_KEY AS `KEY`, COLUMN_DEFAULT AS `DEFAULT`, EXTRA, " +
		"COLUMN_COMMENT AS `COMMENT` FROM information_schema.COLUMNS " +
		"WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION"
	rs, err := d.QueryArgs(ctx, q, maxRows, d.cfg.Name, table)
	if err != nil {
		return nil, err
	}
	if len(rs.Rows) == 0 {
		return nil, d.tableNotFound(table)
	}
	return rs, nil
}

// Indexes 返回表的索引（主键在前，其余按名字排序）。
func (d *DB) Indexes(ctx context.Context, table string, maxRows int) (*ResultSet, error) {
	q := "SELECT INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, EXPRESSION, INDEX_TYPE, INDEX_COMMENT " +
		"FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? " +
		"ORDER BY INDEX_NAME, SEQ_IN_INDEX"
	raw, err := d.QueryArgs(ctx, q, maxRows, d.cfg.Name, table)
	if err != nil {
		return nil, err
	}
	if len(raw.Rows) == 0 {
		// 0 行有两种可能：表不存在，或表没有任何索引（InnoDB 隐藏聚簇索引不在此视图里）。
		exists, err := d.TableExists(ctx, table)
		if err != nil {
			return nil, err
		}
		if !exists {
			return nil, d.tableNotFound(table)
		}
		return NewResultSet(
			TextCol("INDEX"), TextCol("UNIQUE"), TextCol("COLUMNS"), TextCol("TYPE"), TextCol("COMMENT"),
		), nil
	}

	type idxInfo struct {
		name    string
		unique  bool
		typ     string
		comment string
		cols    []string
	}
	ordered := make([]*idxInfo, 0, 4)
	byName := make(map[string]*idxInfo)
	for _, row := range raw.Rows {
		// 列顺序：INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME, EXPRESSION, INDEX_TYPE, INDEX_COMMENT
		name := row[0].Val
		info, ok := byName[name]
		if !ok {
			unique := row[1].Val == "0"
			info = &idxInfo{name: name, unique: unique, typ: row[5].Val, comment: row[6].Val}
			byName[name] = info
			ordered = append(ordered, info)
		}
		switch {
		case !row[3].Null:
			info.cols = append(info.cols, row[3].Val)
		case !row[4].Null: // 函数索引：没有列名时用表达式
			info.cols = append(info.cols, "("+row[4].Val+")")
		}
	}

	// 主键排最前，其余按名字排序。
	sort.SliceStable(ordered, func(i, j int) bool {
		if (ordered[i].name == "PRIMARY") != (ordered[j].name == "PRIMARY") {
			return ordered[i].name == "PRIMARY"
		}
		return ordered[i].name < ordered[j].name
	})

	rs := NewResultSet(
		TextCol("INDEX"), TextCol("UNIQUE"), TextCol("COLUMNS"), TextCol("TYPE"), TextCol("COMMENT"),
	)
	for _, info := range ordered {
		uniq := "NO"
		if info.unique {
			uniq = "YES"
		}
		rs.Add(info.name, uniq, strings.Join(info.cols, ","), info.typ, info.comment)
		if len(rs.Rows) >= maxRows {
			rs.Truncated = len(ordered) > maxRows
			break
		}
	}
	return rs, nil
}

// TableExists 判断当前库中是否存在指定表/视图。
func (d *DB) TableExists(ctx context.Context, table string) (bool, error) {
	v, err := d.ScalarArgs(ctx,
		"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
		d.cfg.Name, table)
	if err != nil {
		return false, err
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return false, fmt.Errorf("unexpected COUNT(*) value %q", v)
	}
	return n > 0, nil
}

// ShowCreateTable 返回 SHOW CREATE TABLE 的 DDL 原文。
func (d *DB) ShowCreateTable(ctx context.Context, table string) (string, error) {
	q := "SHOW CREATE TABLE " + quoteIdent(d.cfg.Name) + "." + quoteIdent(table)
	rs, err := d.Query(ctx, q, 1)
	if err != nil {
		if IsTableNotFound(err) {
			return "", d.tableNotFound(table)
		}
		return "", err
	}
	if len(rs.Rows) == 0 || len(rs.Rows[0]) < 2 || rs.Rows[0][1].Null {
		return "", fmt.Errorf("SHOW CREATE TABLE returned no DDL for table %q", table)
	}
	return rs.Rows[0][1].Val, nil
}

// Find 按关键字模糊搜索表名/表注释/列名/列注释。
// 关键字大小写不敏感：
//   - 不含 LIKE 通配符（% 或 _）时按"包含"匹配，自动包成 %keyword%，
//     因此 `find order` 能命中 sale_order；
//   - 已含 % 或 _ 时原样透传给 SQL LIKE，让调用方精确控制模式（如 `find 'sale_%'`）。
func (d *DB) Find(ctx context.Context, keyword string, maxRows int) (*ResultSet, error) {
	pattern := keyword
	if !strings.ContainsAny(keyword, "%_") {
		pattern = "%" + keyword + "%"
	}
	tables, err := d.QueryArgs(ctx,
		"SELECT TABLE_NAME, TABLE_TYPE, TABLE_COMMENT FROM information_schema.TABLES "+
			"WHERE TABLE_SCHEMA = ? AND (TABLE_NAME LIKE ? OR TABLE_COMMENT LIKE ?) ORDER BY TABLE_NAME",
		maxRows, d.cfg.Name, pattern, pattern)
	if err != nil {
		return nil, err
	}
	// 列的匹配按列名排序（SPEC §3.9：各自按名字排序）。
	cols, err := d.QueryArgs(ctx,
		"SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, COLUMN_COMMENT FROM information_schema.COLUMNS "+
			"WHERE TABLE_SCHEMA = ? AND (COLUMN_NAME LIKE ? OR COLUMN_COMMENT LIKE ?) "+
			"ORDER BY COLUMN_NAME, TABLE_NAME",
		maxRows, d.cfg.Name, pattern, pattern)
	if err != nil {
		return nil, err
	}

	rs := NewResultSet(
		TextCol("KIND"), TextCol("TABLE"), TextCol("COLUMN"), TextCol("TYPE"), TextCol("COMMENT"),
	)
	for _, row := range tables.Rows {
		rs.Add("TABLE", row[0].Val, nil, row[1].Val, row[2].Val)
	}
	for _, row := range cols.Rows {
		rs.Add("COLUMN", row[0].Val, row[1].Val, row[2].Val, row[3].Val)
	}
	if len(rs.Rows) > maxRows {
		rs.Rows = rs.Rows[:maxRows]
		rs.Truncated = true
	}
	if tables.Truncated || cols.Truncated {
		rs.Truncated = true
	}
	return rs, nil
}
