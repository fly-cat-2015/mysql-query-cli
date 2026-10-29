package guard

import (
	"strings"
	"testing"
)

// TestCheck 表驱动覆盖 SPEC §6.2 的判定规则与 §7 拦截矩阵中的词法部分。
//
// 正例里刻意包含字符串/反引号/注释中出现写关键字的写法，
// 反例里刻意包含大小写混淆、多语句、版本注释、危险短语等绕过尝试。
func TestCheck(t *testing.T) {
	tests := []struct {
		name        string
		sql         string
		wantBlocked bool
		wantSubstr  string // 被拦截时，错误信息里必须出现的内容
	}{
		// ---------------- 正例：只读语句 ----------------
		{name: "simple select", sql: "SELECT 1"},
		{name: "lowercase select", sql: "select 1"},
		{name: "select table", sql: "SELECT * FROM sale_pay"},
		{name: "select join", sql: "SELECT o.id, p.name FROM sale_order o JOIN sale_pay p ON p.order_id = o.id WHERE o.id > 10"},
		{name: "select with alias", sql: "SELECT COUNT(*) AS total FROM after_sale_reason"},
		{name: "select information_schema", sql: "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'bbc'"},
		{name: "trailing semicolon", sql: "SELECT 1;"},
		{name: "trailing semicolon spaces", sql: "  SELECT 1 ;  \n\t"},
		{name: "with select", sql: "WITH a AS (SELECT 1) SELECT * FROM a"},
		{name: "with recursive", sql: "WITH RECURSIVE seq AS (SELECT 1 UNION ALL SELECT 1) SELECT * FROM seq"},
		{name: "show tables", sql: "SHOW TABLES"},
		{name: "show columns", sql: "SHOW COLUMNS FROM sale_pay"},
		{name: "desc", sql: "DESC sale_pay"},
		{name: "describe", sql: "DESCRIBE `bbc`.`sale_pay`"},
		{name: "explain", sql: "EXPLAIN SELECT 1"},
		{name: "explain format", sql: "EXPLAIN FORMAT=JSON SELECT * FROM sale_pay"},
		{name: "string contains delete", sql: "SELECT 'DELETE FROM sale_pay' AS msg"},
		{name: "string contains insert", sql: `SELECT "INSERT INTO t VALUES (1)"`},
		{name: "string doubled quote", sql: "SELECT 'it''s a DELETE test' AS s"},
		{name: "string backslash escape", sql: `SELECT 'a\'DELETE' AS s`},
		{name: "backtick update", sql: "SELECT `update` FROM t"},
		{name: "backtick drop table", sql: "SELECT `drop table`, `set`, `insert` FROM t"},
		{name: "backtick doubled", sql: "SELECT `we``ird` FROM t"},
		{name: "line comment", sql: "SELECT 1 -- DELETE FROM sale_pay\n"},
		{name: "hash comment", sql: "SELECT 1 # DROP TABLE sale_pay\n"},
		{name: "block comment", sql: "SELECT /* INSERT UPDATE DELETE */ 1"},
		{name: "optimizer hint", sql: "SELECT /*+ MAX_EXECUTION_TIME(1000) */ 1"},
		{name: "unicode identifier", sql: "SELECT 中文列, `中文` FROM 表名"},
		{name: "unicode space between tokens", sql: "SELECT\u30001"},
		{name: "qualified name", sql: "SELECT a.b FROM `bbc`.sale_pay AS a"},
		{name: "like wildcard", sql: "SELECT * FROM sale_order WHERE order_no LIKE '%2024%'"},
		{name: "comment before select", sql: "/* hi */ SELECT 1"},
		{name: "minus minus not comment", sql: "SELECT 1 - -1"},
		{name: "dash dash without space", sql: "SELECT 1 --2"},

		// ---------------- 反例：空语句/长度 ----------------
		{name: "empty", sql: "", wantBlocked: true, wantSubstr: "empty statement"},
		{name: "spaces only", sql: "   \n\t  ", wantBlocked: true, wantSubstr: "empty statement"},
		{name: "semicolon only", sql: ";", wantBlocked: true, wantSubstr: "empty statement"},
		{name: "semicolons only", sql: " ;; ", wantBlocked: true, wantSubstr: "empty statement"},
		{name: "too long", sql: "SELECT 1" + strings.Repeat(" ", MaxStatementBytes), wantBlocked: true, wantSubstr: "too long"},

		// ---------------- 反例：多语句 ----------------
		{name: "multi statement drop", sql: "SELECT 1; DROP TABLE sale_pay", wantBlocked: true, wantSubstr: "multiple statements"},
		{name: "multi statement select", sql: "SELECT 1; SELECT 2", wantBlocked: true, wantSubstr: "multiple statements"},
		{name: "double semicolon", sql: "SELECT 1;;", wantBlocked: true, wantSubstr: "multiple statements"},
		{name: "multi with trailing", sql: "SELECT 1; DROP TABLE x;", wantBlocked: true, wantSubstr: "multiple statements"},

		// ---------------- 反例：数据写 ----------------
		{name: "insert", sql: "INSERT INTO sale_pay (id) VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},
		{name: "insert lowercase", sql: "insert into sale_pay values (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},
		{name: "insert mixed case", sql: "InSeRt Into sale_pay Values (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},
		{name: "update", sql: "UPDATE sale_pay SET amount = 1", wantBlocked: true, wantSubstr: `forbidden keyword "UPDATE"`},
		{name: "delete", sql: "DELETE FROM sale_pay WHERE id = 1", wantBlocked: true, wantSubstr: `forbidden keyword "DELETE"`},
		{name: "replace", sql: "REPLACE INTO sale_pay (id) VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "REPLACE"`},
		{name: "select then update", sql: "SELECT * FROM sale_pay FOR UPDATE", wantBlocked: true, wantSubstr: "forbidden"},
		{name: "select for share", sql: "SELECT * FROM sale_pay FOR SHARE", wantBlocked: true, wantSubstr: `forbidden phrase "FOR SHARE"`},
		{name: "lock in share mode", sql: "SELECT * FROM sale_pay LOCK IN SHARE MODE", wantBlocked: true, wantSubstr: "forbidden"},
		{name: "select into outfile", sql: "SELECT 1 INTO OUTFILE '/tmp/x'", wantBlocked: true, wantSubstr: "forbidden"},
		{name: "select into dumpfile", sql: "SELECT 1 INTO DUMPFILE '/tmp/x'", wantBlocked: true, wantSubstr: "forbidden"},
		{name: "select into variable", sql: "SELECT 1 INTO @x", wantBlocked: true, wantSubstr: `forbidden keyword "INTO"`},

		// ---------------- 反例：结构改 ----------------
		{name: "create table", sql: "CREATE TABLE t_x (id INT)", wantBlocked: true, wantSubstr: `forbidden keyword "CREATE"`},
		{name: "alter table", sql: "ALTER TABLE sale_pay ADD COLUMN c INT", wantBlocked: true, wantSubstr: `forbidden keyword "ALTER"`},
		{name: "drop table", sql: "DROP TABLE sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "DROP"`},
		{name: "truncate", sql: "TRUNCATE sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "TRUNCATE"`},
		{name: "rename table", sql: "RENAME TABLE sale_pay TO sale_pay_bak", wantBlocked: true, wantSubstr: `forbidden keyword "RENAME"`},
		{name: "create with prefix", sql: "WITH a AS (SELECT 1) CREATE TABLE x (id INT)", wantBlocked: true, wantSubstr: `forbidden keyword "CREATE"`},
		{name: "with delete", sql: "WITH a AS (SELECT 1) DELETE FROM sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "DELETE"`},
		{name: "with update", sql: "WITH a AS (SELECT 1) UPDATE sale_pay SET amount = 0", wantBlocked: true, wantSubstr: `forbidden keyword "UPDATE"`},

		// ---------------- 反例：权限/会话 ----------------
		{name: "grant", sql: "GRANT SELECT ON *.* TO x", wantBlocked: true, wantSubstr: `forbidden keyword "GRANT"`},
		{name: "revoke", sql: "REVOKE SELECT ON *.* FROM x", wantBlocked: true, wantSubstr: `forbidden keyword "REVOKE"`},
		{name: "set session", sql: "SET SESSION TRANSACTION READ WRITE", wantBlocked: true, wantSubstr: `forbidden keyword "SET"`},
		{name: "use db", sql: "USE mysql", wantBlocked: true, wantSubstr: `forbidden keyword "USE"`},
		{name: "start transaction", sql: "START TRANSACTION", wantBlocked: true, wantSubstr: `forbidden keyword "START"`},
		{name: "begin", sql: "BEGIN", wantBlocked: true, wantSubstr: `forbidden keyword "BEGIN"`},
		{name: "commit", sql: "COMMIT", wantBlocked: true, wantSubstr: `forbidden keyword "COMMIT"`},
		{name: "rollback", sql: "ROLLBACK", wantBlocked: true, wantSubstr: `forbidden keyword "ROLLBACK"`},
		{name: "call", sql: "CALL some_proc()", wantBlocked: true, wantSubstr: `forbidden keyword "CALL"`},
		{name: "do sleep", sql: "DO SLEEP(1)", wantBlocked: true, wantSubstr: `forbidden keyword "DO"`},
		{name: "handler", sql: "HANDLER sale_pay OPEN", wantBlocked: true, wantSubstr: `forbidden keyword "HANDLER"`},
		{name: "load data", sql: "LOAD DATA INFILE '/tmp/x' INTO TABLE t", wantBlocked: true, wantSubstr: `forbidden keyword "LOAD"`},
		{name: "prepare", sql: "PREPARE s FROM 'DROP TABLE sale_pay'", wantBlocked: true, wantSubstr: `forbidden keyword "PREPARE"`},
		{name: "execute", sql: "EXECUTE s", wantBlocked: true, wantSubstr: `forbidden keyword "EXECUTE"`},
		{name: "optimize", sql: "OPTIMIZE TABLE sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "OPTIMIZE"`},
		{name: "analyze", sql: "ANALYZE TABLE sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "ANALYZE"`},
		{name: "lock tables", sql: "LOCK TABLES sale_pay WRITE", wantBlocked: true, wantSubstr: `forbidden keyword "LOCK"`},
		{name: "kill", sql: "KILL 123", wantBlocked: true, wantSubstr: `forbidden keyword "KILL"`},
		{name: "grant not first token", sql: "SELECT 1 UNION SELECT 2 FROM x WHERE a = GRANT", wantBlocked: true, wantSubstr: `forbidden keyword "GRANT"`},

		// ---------------- 反例：注释/大小写绕过 ----------------
		{name: "versioned comment", sql: "/*!50000 DROP TABLE sale_pay */", wantBlocked: true, wantSubstr: "versioned comment"},
		{name: "versioned comment inline", sql: "SELECT 1 /*!50000 ; DROP TABLE sale_pay */", wantBlocked: true, wantSubstr: "versioned comment"},
		{name: "versioned comment lowercase", sql: "/*!40101 SET @a=1 */", wantBlocked: true, wantSubstr: "versioned comment"},
		{name: "comment then insert", sql: "/*x*/ INSERT INTO sale_pay VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},
		{name: "comment between tokens", sql: "SEL/**/ECT 1", wantBlocked: true, wantSubstr: "must start with"},
		{name: "comment inside insert word", sql: "IN/*x*/SERT INTO t VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INTO"`},
		{name: "newline before insert", sql: "\n\n  INSERT INTO t VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},
		{name: "unicode space before insert", sql: "\u3000INSERT INTO sale_pay (id) VALUES (1)", wantBlocked: true, wantSubstr: `forbidden keyword "INSERT"`},

		// ---------------- 反例：首 token 非白名单 ----------------
		{name: "table statement", sql: "TABLE sale_pay", wantBlocked: true, wantSubstr: "must start with"},
		{name: "values statement", sql: "VALUES ROW(1)", wantBlocked: true, wantSubstr: "must start with"},
		{name: "parenthesized select", sql: "(SELECT 1)", wantBlocked: true, wantSubstr: "must start with"},
		{name: "show create table", sql: "SHOW CREATE TABLE sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "CREATE"`},
		{name: "explain delete", sql: "EXPLAIN DELETE FROM sale_pay", wantBlocked: true, wantSubstr: `forbidden keyword "DELETE"`},

		// ---------------- 反例：词法无法解析 ----------------
		{name: "unterminated string", sql: "SELECT 'abc", wantBlocked: true, wantSubstr: "unterminated string"},
		{name: "unterminated comment", sql: "SELECT 1 /* abc", wantBlocked: true, wantSubstr: "unterminated"},
		{name: "unterminated backtick", sql: "SELECT `abc", wantBlocked: true, wantSubstr: "unterminated backtick"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			err := Check(tc.sql)
			if tc.wantBlocked {
				if err == nil {
					t.Fatalf("Check(%q) = nil, want blocked", tc.sql)
				}
				be, ok := err.(*BlockedError)
				if !ok {
					t.Fatalf("Check(%q) error type = %T, want *BlockedError", tc.sql, err)
				}
				if be.Reason == "" {
					t.Fatalf("Check(%q) blocked with empty reason", tc.sql)
				}
				if !strings.Contains(err.Error(), tc.wantSubstr) {
					t.Fatalf("Check(%q) error = %q, want substring %q", tc.sql, err.Error(), tc.wantSubstr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Check(%q) = %v, want allowed", tc.sql, err)
			}
		})
	}
}

// TestTokenizeCommentsAndStrings 验证 tokenizer 对注释/字符串/反引号的关键行为。
func TestTokenizeCommentsAndStrings(t *testing.T) {
	toks, err := Tokenize("SELECT 'DELETE', `INSERT`, /* DROP */ 1 -- UPDATE\n")
	if err != nil {
		t.Fatalf("Tokenize: %v", err)
	}
	var kinds []TokenKind
	var words []string
	for _, tk := range toks {
		kinds = append(kinds, tk.Kind)
		if tk.Kind == KindWord {
			words = append(words, tk.Word)
		}
	}
	wantKinds := []TokenKind{KindWord, KindString, KindPunct, KindQuotedIdent, KindPunct, KindNumber}
	if len(kinds) != len(wantKinds) {
		t.Fatalf("token kinds = %v, want %v", kinds, wantKinds)
	}
	for i := range wantKinds {
		if kinds[i] != wantKinds[i] {
			t.Fatalf("token[%d] kind = %v, want %v (all=%v)", i, kinds[i], wantKinds[i], kinds)
		}
	}
	if len(words) != 1 || words[0] != "SELECT" {
		t.Fatalf("words = %v, want [SELECT]", words)
	}
}

// TestTokenizePositions 验证错误位置信息（行/列）可用于提示。
func TestTokenizePositions(t *testing.T) {
	_, err := Tokenize("SELECT 1,\n  'unterminated")
	if err == nil {
		t.Fatal("Tokenize accepted unterminated string")
	}
	se, ok := err.(*SyntaxError)
	if !ok {
		t.Fatalf("error type = %T, want *SyntaxError", err)
	}
	if se.Line != 2 || se.Col != 3 {
		t.Fatalf("position = line %d col %d, want line 2 col 3", se.Line, se.Col)
	}
}
