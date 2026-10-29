package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// clearEnv 清空可能影响配置加载的环境变量，保证测试确定性。
func clearEnv(t *testing.T) {
	t.Helper()
	for _, k := range []string{"MYSQLQ_HOST", "MYSQLQ_PORT", "MYSQLQ_DB", "MYSQLQ_USER", "MYSQLQ_PASSWORD", "MYSQLQ_CONFIG"} {
		t.Setenv(k, "")
	}
}

func writeConfig(t *testing.T, content string) string {
	t.Helper()
	dir := t.TempDir()
	p := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	return p
}

const baseConfig = "db_host: 127.0.0.1\ndb_name: bbc\ndb_user: root\ndb_passwd: root\n"

// TestMaxRows 覆盖 SPEC §2/§3 的行数规则：默认 20、config 可调、>100 钳制并警告、
// 非法值属于配置错误。
func TestMaxRows(t *testing.T) {
	cases := []struct {
		name     string
		extra    string
		want     int
		wantWarn string
		wantErr  string
	}{
		{name: "default is 20", extra: "", want: DefaultMaxRows},
		{name: "config 50", extra: "max_rows: 50\n", want: 50},
		{name: "config 1", extra: "max_rows: 1\n", want: 1},
		{name: "config 100", extra: "max_rows: 100\n", want: 100},
		{
			name:     "config 500 clamps to 100 with warning",
			extra:    "max_rows: 500\n",
			want:     HardMaxRows,
			wantWarn: "max_rows 500 in config exceeds the hard limit 100, using 100",
		},
		{name: "config 0 is an error", extra: "max_rows: 0\n", wantErr: "invalid max_rows"},
		{name: "config negative is an error", extra: "max_rows: -3\n", wantErr: "invalid max_rows"},
		{name: "config text is an error", extra: "max_rows: abc\n", wantErr: "invalid max_rows"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clearEnv(t)
			path := writeConfig(t, baseConfig+tc.extra)
			cfg, err := Load(path, "")
			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("Load() = %+v, want config error", cfg)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("error = %q, want substring %q", err.Error(), tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Load() error = %v", err)
			}
			if cfg.MaxRows != tc.want {
				t.Fatalf("MaxRows = %d, want %d", cfg.MaxRows, tc.want)
			}
			if tc.wantWarn != "" {
				if len(cfg.Warnings) == 0 || !strings.Contains(strings.Join(cfg.Warnings, "\n"), tc.wantWarn) {
					t.Fatalf("Warnings = %v, want substring %q", cfg.Warnings, tc.wantWarn)
				}
			}
			if cfg.MaxRows > HardMaxRows {
				t.Fatalf("MaxRows = %d exceeds hard limit %d", cfg.MaxRows, HardMaxRows)
			}
		})
	}
}

// TestParseRules 覆盖扁平 YAML 子集解析：引号、值中 #、别名、未知键、端口校验。
func TestParseRules(t *testing.T) {
	clearEnv(t)
	path := writeConfig(t, ""+
		"# comment line\n"+
		"db_host: \"127.0.0.1\"\n"+
		"db_port: 3307\n"+
		"db_name: 'bbc'\n"+
		"db_user: root\n"+
		"db_passwd: 'pa#ss:word'\n"+
		"db_charset: utf8mb4\n"+
		"max_rows: 30\n"+
		"unknown_key: whatever\n")
	cfg, err := Load(path, "")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Host != "127.0.0.1" || cfg.Port != 3307 || cfg.Name != "bbc" || cfg.User != "root" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
	// 值中间的 # 不能当注释（密码不能被截断）
	if cfg.Passwd != "pa#ss:word" {
		t.Fatalf("Passwd = %q, want %q", cfg.Passwd, "pa#ss:word")
	}
	if cfg.MaxRows != 30 {
		t.Fatalf("MaxRows = %d, want 30", cfg.MaxRows)
	}

	// db_password 是 db_passwd 的别名
	clearEnv(t)
	path2 := writeConfig(t, baseConfig+"db_password: secret\n")
	cfg2, err := Load(path2, "")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg2.Passwd != "secret" {
		t.Fatalf("Passwd = %q, want secret (db_password alias)", cfg2.Passwd)
	}

	// db_port 非法 → 配置错误
	clearEnv(t)
	path3 := writeConfig(t, "db_host: h\ndb_port: not-a-port\ndb_name: bbc\ndb_user: root\n")
	if _, err := Load(path3, ""); err == nil || !strings.Contains(err.Error(), "db_port") {
		t.Fatalf("Load() error = %v, want db_port error", err)
	}
}

// TestOverrides 覆盖 --db 与环境变量覆盖的优先级。
func TestOverrides(t *testing.T) {
	clearEnv(t)
	path := writeConfig(t, baseConfig)
	cfg, err := Load(path, "other_db")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Name != "other_db" {
		t.Fatalf("Name = %q, want other_db (flag wins)", cfg.Name)
	}

	clearEnv(t)
	t.Setenv("MYSQLQ_DB", "env_db")
	t.Setenv("MYSQLQ_USER", "env_user")
	cfg, err = Load(path, "")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if cfg.Name != "env_db" || cfg.User != "env_user" {
		t.Fatalf("env override failed: name=%q user=%q", cfg.Name, cfg.User)
	}
}

// TestCandidatePathsOrder 锁定默认查找顺序：可执行文件同目录优先，当前目录兜底。
//
// 部署约定（SPEC §2）：mysqlq.exe、config.yaml、SKILL.md 同目录，从任意 cwd 调用
// 都默认读可执行文件旁边的配置。
func TestCandidatePathsOrder(t *testing.T) {
	clearEnv(t)
	paths := candidatePaths()
	if len(paths) < 2 {
		t.Fatalf("candidatePaths() = %v, want exe dir + cwd", paths)
	}
	exeDirPath := paths[0]
	if !strings.HasSuffix(strings.ToLower(exeDirPath), "config.yaml") {
		t.Fatalf("first candidate = %q, want <exe dir>/config.yaml", exeDirPath)
	}
	if exeDirPath == "./config.yaml" {
		t.Fatalf("first candidate must be the exe directory, got %q", exeDirPath)
	}
	// 测试二进制在临时目录里，exe 目录必然不同于仓库目录；最后一个候选是 cwd 兜底。
	if last := paths[len(paths)-1]; last != "./config.yaml" {
		t.Fatalf("last candidate = %q, want ./config.yaml fallback", last)
	}

	// LookedPaths 顺序：--config > $MYSQLQ_CONFIG > 默认候选
	t.Setenv("MYSQLQ_CONFIG", "env-config.yaml")
	looked := LookedPaths("explicit.yaml")
	if len(looked) < 3 || looked[0] != "explicit.yaml" || looked[1] != "env-config.yaml" {
		t.Fatalf("LookedPaths = %v, want [explicit, env, <exe>/config.yaml, ./config.yaml]", looked)
	}
	if looked[2] != paths[0] {
		t.Fatalf("LookedPaths default candidates = %v, want %v", looked[2:], paths)
	}
}

// TestLocateFallsBackToCwd 验证默认查找在 exe 同目录没有配置时会回落到当前工作目录
// （`go run .` 等二进制不在部署目录的场景），并且 Source 是绝对路径。
func TestLocateFallsBackToCwd(t *testing.T) {
	clearEnv(t)
	dir := t.TempDir()
	cfgPath := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(cfgPath, []byte(baseConfig), 0o600); err != nil {
		t.Fatalf("write temp config: %v", err)
	}
	oldWd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("Chdir: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(oldWd) })

	cfg, err := Load("", "")
	if err != nil {
		t.Fatalf("Load() error = %v", err)
	}
	if filepath.Clean(cfg.Source) != filepath.Clean(cfgPath) {
		t.Fatalf("Source = %q, want %q", cfg.Source, cfgPath)
	}
	if !filepath.IsAbs(cfg.Source) {
		t.Fatalf("Source = %q, want absolute path", cfg.Source)
	}
}

// TestMissingConfig 覆盖找不到配置文件时的可操作错误。
func TestMissingConfig(t *testing.T) {
	clearEnv(t)
	missing := filepath.Join(t.TempDir(), "nope.yaml")
	_, err := Load(missing, "")
	if err == nil {
		t.Fatal("Load() = nil, want error for missing config")
	}
	msg := err.Error()
	if !strings.Contains(msg, "does not exist") || !strings.Contains(msg, "--config") {
		t.Fatalf("error = %q, want actionable missing-config message", msg)
	}
}
