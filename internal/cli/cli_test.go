package cli

import (
	"bytes"
	"strings"
	"testing"
)

// runCLI 用内存流执行一次 CLI，返回退出码与 stdout/stderr。
// 只用于不需要连库的路径（用法错误、拦截、version/help）。
func runCLI(t *testing.T, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	code := Execute(args, strings.NewReader(""), &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

// TestParseArgs 覆盖全局参数解析（参数可出现在子命令前后）与 --max-rows 取值范围。
func TestParseArgs(t *testing.T) {
	o, err := parseArgs([]string{"query", "SELECT 1", "--max-rows", "5", "--format", "json"})
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}
	if o.command != "query" || len(o.args) != 1 || o.args[0] != "SELECT 1" {
		t.Fatalf("unexpected command/args: %+v", o)
	}
	if !o.maxRowsSet || o.maxRows != 5 {
		t.Fatalf("maxRows = %d set=%v, want 5/true", o.maxRows, o.maxRowsSet)
	}
	if o.format != "json" {
		t.Fatalf("format = %q, want json", o.format)
	}

	// 等于号写法 + 参数在子命令之前
	o, err = parseArgs([]string{"--max-rows=100", "--db", "bbc", "tables", "--all"})
	if err != nil {
		t.Fatalf("parseArgs() error = %v", err)
	}
	if o.maxRows != 100 || !o.maxRowsSet || o.dbOverride != "bbc" || !o.all || o.command != "tables" {
		t.Fatalf("unexpected options: %+v", o)
	}

	// 1..100 之外都是用法错误
	for _, bad := range []string{"0", "-1", "101", "1000", "abc", ""} {
		if _, err := parseArgs([]string{"query", "SELECT 1", "--max-rows", bad}); err == nil {
			t.Fatalf("parseArgs(--max-rows %q) accepted, want usage error", bad)
		}
	}

	// 非法 format / timeout
	if _, err := parseArgs([]string{"query", "x", "--format", "xml"}); err == nil {
		t.Fatal("invalid --format accepted")
	}
	if _, err := parseArgs([]string{"query", "x", "--timeout", "soon"}); err == nil {
		t.Fatal("invalid --timeout accepted")
	}
}

// TestMaxRowsUsageErrors 覆盖 --max-rows 越界时 exit 2 且 stdout 为空。
func TestMaxRowsUsageErrors(t *testing.T) {
	for _, bad := range []string{"101", "0"} {
		code, out, errText := runCLI(t, "query", "SELECT 1", "--max-rows", bad)
		if code != 2 {
			t.Fatalf("--max-rows %s: exit = %d, want 2", bad, code)
		}
		if out != "" {
			t.Fatalf("--max-rows %s: stdout = %q, want empty", bad, out)
		}
		if !strings.Contains(errText, "between 1 and 100") {
			t.Fatalf("--max-rows %s: stderr = %q, want range message", bad, errText)
		}
	}
}

// TestGuardRunsBeforeConfig 证明拦截发生在读取配置/连库之前：
// 即使 --config 指向不存在的文件，写 SQL 仍然是 exit 3 而不是配置错误。
func TestGuardRunsBeforeConfig(t *testing.T) {
	code, out, errText := runCLI(t,
		"--config", "definitely-not-a-config-file.yaml",
		"query", "DELETE FROM sale_pay WHERE id = 1")
	if code != 3 {
		t.Fatalf("exit = %d, want 3 (blocked before config)", code)
	}
	if out != "" {
		t.Fatalf("stdout = %q, want empty", out)
	}
	if !strings.Contains(errText, "blocked") || !strings.Contains(errText, "DELETE") {
		t.Fatalf("stderr = %q, want blocked + keyword", errText)
	}
}

// TestBlockedVariants 覆盖黑盒常见绕过写法都必须在连库前被拦截。
func TestBlockedVariants(t *testing.T) {
	cases := []string{
		"INSERT INTO sale_pay (id) VALUES (1)",
		"insert   into sale_pay values (1)",
		"InSeRt InTo sale_pay values (1)",
		"UPDATE sale_pay SET pay_status = 'x'",
		"DROP TABLE sale_pay",
		"SELECT 1; DROP TABLE sale_pay",
		"/*!50000 DROP TABLE sale_pay */",
		"WITH a AS (SELECT 1) DELETE FROM sale_pay",
		"SELECT 1 INTO OUTFILE '/tmp/x'",
		"SELECT * FROM sale_pay FOR UPDATE",
	}
	for _, sqlText := range cases {
		code, out, errText := runCLI(t, "query", sqlText)
		if code != 3 {
			t.Fatalf("query %q: exit = %d, want 3", sqlText, code)
		}
		if out != "" {
			t.Fatalf("query %q: stdout = %q, want empty", sqlText, out)
		}
		if !strings.Contains(errText, "blocked") {
			t.Fatalf("query %q: stderr = %q, want blocked", sqlText, errText)
		}
	}
}

// TestUsageAndVersion 覆盖不需要连库的命令与用法错误。
func TestUsageAndVersion(t *testing.T) {
	code, out, _ := runCLI(t, "version")
	if code != 0 || out != "mysqlq "+Version+"\n" {
		t.Fatalf("version: exit=%d out=%q", code, out)
	}

	code, out, _ = runCLI(t, "--help")
	if code != 0 || !strings.Contains(out, "Usage:") || !strings.Contains(out, "--max-rows") {
		t.Fatalf("--help: exit=%d out=%q", code, out)
	}

	code, out, _ = runCLI(t)
	if code != 2 || !strings.Contains(out, "Usage:") {
		t.Fatalf("no command: exit=%d out=%q (want usage on stdout, exit 2)", code, out)
	}

	code, out, errText := runCLI(t, "nosuchcommand")
	if code != 2 || out != "" || !strings.Contains(errText, "unknown command") {
		t.Fatalf("unknown command: exit=%d out=%q err=%q", code, out, errText)
	}

	// query - 从空 stdin 读取 → 用法错误
	code, _, errText = runCLI(t, "query", "-")
	if code != 2 || !strings.Contains(errText, "stdin") {
		t.Fatalf("empty stdin: exit=%d err=%q", code, errText)
	}
}
