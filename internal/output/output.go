// Package output 负责把查询结果渲染成 table / json / csv / md 四种格式。
//
// 约定（SPEC §4）：stdout 只放数据；行数统计、截断提示、警告由 CLI 写到 stderr。
package output

import (
	"encoding/base64"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"mysql-query-cli/internal/db"
)

// Format 是输出格式。
type Format string

const (
	// Table 是无边框对齐表格（默认）。
	Table Format = "table"
	// JSON 是美化后的 JSON。
	JSON Format = "json"
	// CSV 是 RFC 4180 风格 CSV。
	CSV Format = "csv"
	// Markdown 是 GitHub 风格 Markdown 表格。
	Markdown Format = "md"
)

// Parse 校验并返回输出格式。
func Parse(s string) (Format, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "table":
		return Table, true
	case "json":
		return JSON, true
	case "csv":
		return CSV, true
	case "md", "markdown":
		return Markdown, true
	}
	return "", false
}

// Render 按格式输出一个结果集（不含行数统计，统计由 CLI 负责）。
func Render(w io.Writer, rs *db.ResultSet, f Format) error {
	switch f {
	case Table:
		return renderTable(w, rs)
	case JSON:
		return renderJSON(w, rs)
	case CSV:
		return renderCSV(w, rs)
	case Markdown:
		return renderMarkdown(w, rs)
	default:
		return fmt.Errorf("unsupported output format %q", string(f))
	}
}

// ---------- table ----------

// renderTable 输出无边框对齐表格：表头、分隔行、数据行。
func renderTable(w io.Writer, rs *db.ResultSet) error {
	n := len(rs.Columns)
	if n == 0 {
		return nil
	}
	cells := make([][]string, len(rs.Rows))
	widths := make([]int, n)
	for i, c := range rs.Columns {
		widths[i] = displayWidth(c.Name)
	}
	for r, row := range rs.Rows {
		cells[r] = make([]string, n)
		for c := 0; c < n; c++ {
			s := ""
			if c < len(row) {
				s = cellText(row[c])
			}
			s = singleLine(s)
			cells[r][c] = s
			if cw := displayWidth(s); cw > widths[c] {
				widths[c] = cw
			}
		}
	}

	var b strings.Builder
	// 表头（左对齐）
	b.WriteString(padRow(colNames(rs.Columns), widths, nil))
	b.WriteString("\n")
	// 分隔行
	seps := make([]string, n)
	for i, c := range rs.Columns {
		cw := widths[i]
		if cw < len(c.Name) {
			cw = len(c.Name)
		}
		seps[i] = strings.Repeat("-", cw)
	}
	b.WriteString(strings.Join(seps, "  "))
	b.WriteString("\n")
	// 数据行：数值列右对齐
	for _, row := range cells {
		b.WriteString(padRow(row, widths, numericFlags(rs.Columns)))
		b.WriteString("\n")
	}
	_, err := io.WriteString(w, b.String())
	return err
}

func colNames(cols []db.Column) []string {
	out := make([]string, len(cols))
	for i, c := range cols {
		out[i] = c.Name
	}
	return out
}

func numericFlags(cols []db.Column) []bool {
	out := make([]bool, len(cols))
	for i, c := range cols {
		out[i] = c.Numeric
	}
	return out
}

// padRow 按列宽补齐一行；numeric[i] 为 true 的列右对齐，其余左对齐。
func padRow(vals []string, widths []int, numeric []bool) string {
	var b strings.Builder
	for i, v := range vals {
		if i > 0 {
			b.WriteString("  ")
		}
		gap := widths[i] - displayWidth(v)
		if gap < 0 {
			gap = 0
		}
		if numeric != nil && i < len(numeric) && numeric[i] {
			b.WriteString(strings.Repeat(" ", gap))
			b.WriteString(v)
		} else {
			b.WriteString(v)
			// 行尾空白由 TrimRight 去掉，这里保留列间隔。
			if i < len(vals)-1 {
				b.WriteString(strings.Repeat(" ", gap))
			}
		}
	}
	return strings.TrimRight(b.String(), " ")
}

// singleLine 把单元格内的换行/制表符替换为空格，避免破坏表格对齐。
func singleLine(s string) string {
	if !strings.ContainsAny(s, "\r\n\t") {
		return s
	}
	return strings.NewReplacer("\r\n", " ", "\r", " ", "\n", " ", "\t", " ").Replace(s)
}

// cellText 返回单元格的展示文本：NULL 显示为 NULL，空字符串显示为空。
func cellText(c db.Cell) string {
	if c.Null {
		return "NULL"
	}
	return c.Val
}

// displayWidth 计算字符串显示宽度（CJK 全角字符按 2 列计）。
func displayWidth(s string) int {
	w := 0
	for _, r := range s {
		w += runeWidth(r)
	}
	return w
}

func runeWidth(r rune) int {
	if r < 0x1100 {
		return 1
	}
	switch {
	case r <= 0x115F, // Hangul Jamo 初声
		r >= 0x2E80 && r <= 0xA4CF && r != 0x303F, // CJK 部首/假名/汉字
		r >= 0xAC00 && r <= 0xD7A3,                // Hangul 音节
		r >= 0xF900 && r <= 0xFAFF,                // CJK 兼容汉字
		r >= 0xFE30 && r <= 0xFE6F,                // CJK 兼容形式
		r >= 0xFF00 && r <= 0xFF60,                // 全角 ASCII
		r >= 0xFFE0 && r <= 0xFFE6,                // 全角符号
		r >= 0x1F300 && r <= 0x1F64F,              // emoji
		r >= 0x1F900 && r <= 0x1F9FF,              // emoji 补充
		r >= 0x20000 && r <= 0x3FFFD:              // CJK 扩展 B+
		return 2
	}
	return 1
}

// ---------- json ----------

// renderJSON 输出 JSON 数组（美化为 2 空格缩进，UTF-8 原文不转义，末尾换行）。
func renderJSON(w io.Writer, rs *db.ResultSet) error {
	var b strings.Builder
	writeJSONArray(&b, rs, "")
	b.WriteString("\n")
	_, err := io.WriteString(w, b.String())
	return err
}

// RenderSchemaJSON 输出 schema 命令的 JSON 对象（SPEC §3.7 唯一非数组形式）。
func RenderSchemaJSON(w io.Writer, database, table string, columns, indexes *db.ResultSet, ddl string) error {
	var b strings.Builder
	b.WriteString("{\n")
	b.WriteString(`  "database": `)
	writeJSONString(&b, database)
	b.WriteString(",\n")
	b.WriteString(`  "table": `)
	writeJSONString(&b, table)
	b.WriteString(",\n")
	b.WriteString(`  "columns": `)
	writeJSONArray(&b, columns, "  ")
	b.WriteString(",\n")
	b.WriteString(`  "indexes": `)
	writeJSONArray(&b, indexes, "  ")
	b.WriteString(",\n")
	b.WriteString(`  "ddl": `)
	writeJSONString(&b, ddl)
	b.WriteString("\n}\n")
	_, err := io.WriteString(w, b.String())
	return err
}

func writeJSONArray(b *strings.Builder, rs *db.ResultSet, indent string) {
	if rs == nil || len(rs.Rows) == 0 {
		b.WriteString("[]")
		return
	}
	n := len(rs.Columns)
	b.WriteString("[\n")
	for i, row := range rs.Rows {
		b.WriteString(indent)
		b.WriteString("  {\n")
		for j := 0; j < n; j++ {
			b.WriteString(indent)
			b.WriteString("    ")
			writeJSONString(b, rs.Columns[j].Name)
			b.WriteString(": ")
			var cell db.Cell
			if j < len(row) {
				cell = row[j]
			} else {
				cell = db.Cell{Null: true}
			}
			writeJSONCell(b, cell, rs.Columns[j].Numeric)
			if j < n-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(indent)
		b.WriteString("  }")
		if i < len(rs.Rows)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString(indent)
	b.WriteString("]")
}

// writeJSONCell 按 SPEC §4.2 的类型映射写一个值。
// 数值列输出为 JSON 数字；NULL → null；非 UTF-8 二进制 → base64 字符串。
func writeJSONCell(b *strings.Builder, c db.Cell, numeric bool) {
	if c.Null {
		b.WriteString("null")
		return
	}
	if numeric && isJSONNumber(c.Val) {
		// 直接写原始文本，保留 DECIMAL 精度（等价于 json.Number）。
		b.WriteString(c.Val)
		return
	}
	if utf8.ValidString(c.Val) {
		writeJSONString(b, c.Val)
		return
	}
	writeJSONString(b, base64.StdEncoding.EncodeToString([]byte(c.Val)))
}

func writeJSONString(b *strings.Builder, s string) {
	// 用 Encoder 关闭 HTML 转义，保证中文/DDL 里的 < > & 原样输出。
	var buf strings.Builder
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		b.WriteString(strconv.Quote(s))
		return
	}
	b.WriteString(strings.TrimSuffix(buf.String(), "\n"))
}

// isJSONNumber 判断字符串是否是合法的 JSON 数字字面量。
func isJSONNumber(s string) bool {
	if s == "" {
		return false
	}
	i := 0
	if s[i] == '-' {
		i++
	}
	digits := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		i++
		digits++
	}
	if digits == 0 {
		return false
	}
	if i < len(s) && s[i] == '.' {
		i++
		frac := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
			frac++
		}
		if frac == 0 {
			return false
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		i++
		if i < len(s) && (s[i] == '+' || s[i] == '-') {
			i++
		}
		exp := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' {
			i++
			exp++
		}
		if exp == 0 {
			return false
		}
	}
	return i == len(s)
}

// ---------- csv ----------

// renderCSV 输出 RFC 4180 CSV（首行表头、行尾 CRLF、NULL 为空字段）。
func renderCSV(w io.Writer, rs *db.ResultSet) error {
	cw := csv.NewWriter(w)
	cw.UseCRLF = true
	header := make([]string, len(rs.Columns))
	for i, c := range rs.Columns {
		header[i] = c.Name
	}
	if err := cw.Write(header); err != nil {
		return err
	}
	rec := make([]string, len(rs.Columns))
	for _, row := range rs.Rows {
		for i := range rec {
			if i < len(row) && !row[i].Null {
				rec[i] = row[i].Val
			} else {
				rec[i] = ""
			}
		}
		if err := cw.Write(rec); err != nil {
			return err
		}
	}
	cw.Flush()
	return cw.Error()
}

// ---------- md ----------

// renderMarkdown 输出 GitHub 风格 Markdown 表格。
func renderMarkdown(w io.Writer, rs *db.ResultSet) error {
	var b strings.Builder
	b.WriteString("|")
	for _, c := range rs.Columns {
		b.WriteString(" ")
		b.WriteString(mdEscape(c.Name))
		b.WriteString(" |")
	}
	b.WriteString("\n|")
	for range rs.Columns {
		b.WriteString(" --- |")
	}
	b.WriteString("\n")
	for _, row := range rs.Rows {
		b.WriteString("|")
		for i := range rs.Columns {
			var c db.Cell
			if i < len(row) {
				c = row[i]
			} else {
				c = db.Cell{Null: true}
			}
			b.WriteString(" ")
			if c.Null {
				b.WriteString("NULL")
			} else {
				b.WriteString(mdEscape(c.Val))
			}
			b.WriteString(" |")
		}
		b.WriteString("\n")
	}
	_, err := io.WriteString(w, b.String())
	return err
}

// mdEscape 转义 Markdown 表格单元格：`|` → `\|`，换行 → `<br>`。
func mdEscape(s string) string {
	r := strings.NewReplacer(
		"|", `\|`,
		"\r\n", "<br>",
		"\r", "<br>",
		"\n", "<br>",
	)
	return r.Replace(s)
}
