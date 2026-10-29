package guard

import (
	"fmt"
	"strings"
)

// MaxStatementBytes 是允许的单条 SQL 上限（64KB，SPEC §6.2）。
const MaxStatementBytes = 64 * 1024

// 首 token 白名单：只有这些语句类型可能被放行（SPEC §6.2 第 4 条）。
var allowedFirst = map[string]bool{
	"SELECT":   true,
	"WITH":     true,
	"SHOW":     true,
	"DESC":     true,
	"DESCRIBE": true,
	"EXPLAIN":  true,
}

// 黑名单关键字：作为 WORD token 出现即拦截（SPEC §6.2 第 5 条）。
// 字符串字面量与反引号标识符里的内容不算，因为它们不会成为 KindWord。
var forbidden = map[string]bool{
	"INSERT": true, "UPDATE": true, "DELETE": true, "REPLACE": true,
	"MERGE": true, "UPSERT": true, "CREATE": true, "ALTER": true,
	"DROP": true, "TRUNCATE": true, "RENAME": true, "GRANT": true,
	"REVOKE": true, "SET": true, "RESET": true, "CALL": true,
	"DO": true, "LOAD": true, "IMPORT": true, "HANDLER": true,
	"FLUSH": true, "KILL": true, "SHUTDOWN": true, "INSTALL": true,
	"UNINSTALL": true, "PREPARE": true, "EXECUTE": true, "DEALLOCATE": true,
	"XA": true, "START": true, "BEGIN": true, "COMMIT": true,
	"ROLLBACK": true, "SAVEPOINT": true, "RELEASE": true, "LOCK": true,
	"UNLOCK": true, "OPTIMIZE": true, "ANALYZE": true, "REPAIR": true,
	"CHECKSUM": true, "USE": true, "INTO": true, "OUTFILE": true,
	"DUMPFILE": true, "BACKUP": true, "RESTORE": true, "PURGE": true,
}

// 危险短语（相邻 token 匹配，SPEC §6.2 第 6 条）。
// 这些短语即使没有命中上面的单词黑名单（FOR/SHARE/MODE）也必须拦截。
var forbiddenPhrases = [][]string{
	{"FOR", "SHARE"},
	{"LOCK", "IN", "SHARE", "MODE"},
	{"INTO", "OUTFILE"},
	{"INTO", "DUMPFILE"},
}

// BlockedError 表示只读防护拦截（退出码 3，类别 blocked）。
type BlockedError struct {
	// Reason 是可以直接展示给用户的完整原因（英文，便于 agent 解析）。
	Reason string
	// Keyword 是被拦截的关键字/短语（可能为空）。
	Keyword string
}

func (e *BlockedError) Error() string { return e.Reason }

func blockedf(format string, args ...any) *BlockedError {
	return &BlockedError{Reason: fmt.Sprintf(format, args...)}
}

// Check 判断 SQL 是否允许执行；允许返回 nil，否则返回 *BlockedError。
//
// 检查顺序：长度 → 词法（含版本注释） → 空语句 → 单语句 → 危险短语 → 黑名单关键字
// → 首 token 白名单。任何拿不准的情况都拦截（默认拒绝）。
func Check(sql string) error {
	if len(sql) > MaxStatementBytes {
		return blockedf("statement is too long (%d bytes, limit %d bytes); split it into smaller queries",
			len(sql), MaxStatementBytes)
	}

	toks, err := Tokenize(sql)
	if err != nil {
		// 词法层无法安全解析 → 一律拦截（默认拒绝）。
		return &BlockedError{Reason: "cannot safely parse statement: " + err.Error()}
	}
	if len(toks) == 0 {
		return blockedf("empty statement")
	}

	// 只有分号 → 空语句。
	onlySemicolons := true
	for _, t := range toks {
		if t.Kind != KindSemicolon {
			onlySemicolons = false
			break
		}
	}
	if onlySemicolons {
		return blockedf("empty statement")
	}

	// ---- 单语句：只允许至多一个结尾分号 ----
	for idx, t := range toks {
		if t.Kind != KindSemicolon {
			continue
		}
		if idx != len(toks)-1 {
			return blockedf("multiple statements are not allowed (found %q in the middle of the statement)",
				snippet(sql, t))
		}
	}

	// ---- 危险短语（先于黑名单，给出更清晰原因） ----
	if hit := matchPhrase(toks); hit != nil {
		return &BlockedError{
			Reason: fmt.Sprintf("statement contains forbidden phrase %q; this tool only allows read-only queries",
				strings.Join(hit, " ")),
			Keyword: strings.Join(hit, " "),
		}
	}

	// ---- 黑名单关键字（大小写不敏感，字符串/反引号内容不算） ----
	for _, t := range toks {
		if t.Kind == KindWord && forbidden[t.Word] {
			msg := fmt.Sprintf("statement contains forbidden keyword %q; this tool only allows read-only queries", t.Word)
			// 常见误用给出可操作提示：SHOW CREATE TABLE 请改用 ddl 子命令。
			if t.Word == "CREATE" && len(toks) > 1 && toks[0].Kind == KindWord && toks[0].Word == "SHOW" {
				msg += fmt.Sprintf(" (use %q to inspect a table definition)", "mysqlq ddl <table>")
			}
			return &BlockedError{Reason: msg, Keyword: t.Word}
		}
	}

	// ---- 首 token 白名单 ----
	first := toks[0]
	if first.Kind != KindWord || !allowedFirst[first.Word] {
		return blockedf("statement must start with one of SELECT, WITH, SHOW, DESC, DESCRIBE, EXPLAIN; got %q",
			snippet(sql, first))
	}
	return nil
}

// matchPhrase 在 token 序列里查找相邻的危险短语。
//
// 只比较 KindWord 的 token；注释/空白不产生 token，因此天然被跳过。
func matchPhrase(toks []Token) []string {
	for _, phrase := range forbiddenPhrases {
		for i := 0; i+len(phrase) <= len(toks); i++ {
			ok := true
			for j, want := range phrase {
				t := toks[i+j]
				if t.Kind != KindWord || t.Word != want {
					ok = false
					break
				}
			}
			if ok {
				return phrase
			}
		}
	}
	return nil
}

// snippet 返回 token 的可读片段，用于错误提示（多行/超长时截断）。
func snippet(sql string, t Token) string {
	if t.Kind == KindSemicolon {
		return ";"
	}
	s := t.Text
	if len(s) > 40 {
		s = s[:40] + "..."
	}
	return strings.ReplaceAll(strings.ReplaceAll(s, "\n", " "), "\t", " ")
}
