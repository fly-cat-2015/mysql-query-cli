// Package config 负责加载 mysqlq 的配置文件。
//
// 配置文件是一个"扁平 YAML 子集"：每行 `key: value`，不做嵌套、不做列表。
// 这样可以在不引入 yaml 库（SPEC 硬性约束）的前提下满足需求。
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	// DefaultPort 是 db_port 缺省值。
	DefaultPort = 3306
	// DefaultHost 是 db_host 缺省值（避免出现空 DSN 地址）。
	DefaultHost = "127.0.0.1"
	// DefaultCharset 是连接字符集缺省值。
	DefaultCharset = "utf8mb4"
	// DefaultMaxRows 是单次查询返回行数缺省值（SPEC §3）。
	DefaultMaxRows = 20
	// HardMaxRows 是绝对硬上限：任何配置、参数组合都不得超过它（SPEC §3/§6.3）。
	HardMaxRows = 100
)

// Error 表示配置类错误（退出码 1，类别 config）。
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errf(format string, args ...any) error { return &Error{Msg: fmt.Sprintf(format, args...)} }

// Config 是最终生效的运行期配置。
type Config struct {
	Host    string
	Port    int
	Name    string
	User    string
	Passwd  string
	Charset string
	// MaxRows 是最终生效的单次返回行数（1..HardMaxRows，config 超限时已钳制）。
	MaxRows int
	// Source 是实际加载的配置文件绝对路径，供 `info` 展示。
	Source string
	// Warnings 是加载期产生的警告（例如 max_rows 被钳制），由 CLI 打到 stderr。
	Warnings []string
}

// LookedPaths 返回查找配置文件时依次尝试过的位置（仅用于错误提示）。
func LookedPaths(explicit string) []string {
	var out []string
	if explicit != "" {
		out = append(out, explicit)
	}
	if env := os.Getenv("MYSQLQ_CONFIG"); env != "" {
		out = append(out, env)
	}
	out = append(out, "./config.yaml", "../config.yaml")
	if exe, err := os.Executable(); err == nil {
		out = append(out, filepath.Join(filepath.Dir(exe), "config.yaml"))
	}
	return out
}

// Load 按 SPEC §2 的顺序定位并解析配置文件，应用环境变量覆盖与 --db 覆盖，
// 最后校验并计算最终生效的 max_rows。
func Load(explicitPath, dbOverride string) (*Config, error) {
	path, err := locate(explicitPath)
	if err != nil {
		return nil, err
	}
	kv, err := parseFile(path)
	if err != nil {
		return nil, err
	}

	cfg := &Config{
		Host:    DefaultHost,
		Port:    DefaultPort,
		Charset: DefaultCharset,
		MaxRows: DefaultMaxRows,
		Source:  path,
	}

	// ---- 文件键（键名大小写不敏感，未知键忽略） ----
	for k, v := range kv {
		switch k {
		case "db_host":
			cfg.Host = v
		case "db_port":
			port, err := strconv.Atoi(v)
			if err != nil || port < 1 || port > 65535 {
				return nil, errf("invalid db_port %q in %s: expected an integer between 1 and 65535", v, path)
			}
			cfg.Port = port
		case "db_name":
			cfg.Name = v
		case "db_user":
			cfg.User = v
		case "db_passwd", "db_password": // 两个键是别名
			cfg.Passwd = v
		case "db_charset":
			cfg.Charset = v
		case "max_rows":
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				return nil, errf("invalid max_rows %q in %s: expected an integer between 1 and %d", v, path, HardMaxRows)
			}
			if n > HardMaxRows {
				// 超过硬上限不报错：钳制并警告（SPEC §2）。
				cfg.Warnings = append(cfg.Warnings, fmt.Sprintf(
					"max_rows %d in config exceeds the hard limit %d, using %d", n, HardMaxRows, HardMaxRows))
				n = HardMaxRows
			}
			cfg.MaxRows = n
		}
	}

	// ---- 环境变量覆盖（在文件之后生效） ----
	if v := os.Getenv("MYSQLQ_HOST"); v != "" {
		cfg.Host = v
	}
	if v := os.Getenv("MYSQLQ_PORT"); v != "" {
		port, err := strconv.Atoi(v)
		if err != nil || port < 1 || port > 65535 {
			return nil, errf("invalid MYSQLQ_PORT %q: expected an integer between 1 and 65535", v)
		}
		cfg.Port = port
	}
	if v := os.Getenv("MYSQLQ_DB"); v != "" {
		cfg.Name = v
	}
	if v := os.Getenv("MYSQLQ_USER"); v != "" {
		cfg.User = v
	}
	if v := os.Getenv("MYSQLQ_PASSWORD"); v != "" {
		cfg.Passwd = v
	}

	// ---- 命令行 --db 覆盖优先级最高 ----
	if dbOverride != "" {
		cfg.Name = dbOverride
	}

	// ---- 必填项校验：错误信息必须"可操作" ----
	if cfg.Name == "" {
		return nil, errf("db_name is empty: set `db_name: <database>` in %s, or pass --db <name>", path)
	}
	if cfg.User == "" {
		return nil, errf("db_user is empty: set `db_user: <user>` in %s", path)
	}
	if cfg.Charset == "" {
		cfg.Charset = DefaultCharset
	}
	if cfg.Port <= 0 {
		cfg.Port = DefaultPort
	}
	// 最终值再做一次钳制，确保"任何来源都不得超过 100"。
	if cfg.MaxRows < 1 {
		cfg.MaxRows = DefaultMaxRows
	}
	if cfg.MaxRows > HardMaxRows {
		cfg.MaxRows = HardMaxRows
	}
	return cfg, nil
}

// locate 按 SPEC §2 的查找顺序返回第一个存在的配置文件。
func locate(explicitPath string) (string, error) {
	// 1/2. 显式指定（--config 或 MYSQLQ_CONFIG）：找错了要明确报错，而不是静默回退。
	if explicitPath != "" {
		return checkPath(explicitPath, "--config")
	}
	if env := os.Getenv("MYSQLQ_CONFIG"); env != "" {
		return checkPath(env, "MYSQLQ_CONFIG")
	}
	// 3/4. 当前目录、上级目录。5. 可执行文件同目录。
	candidates := []string{"./config.yaml", "../config.yaml"}
	if exe, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Join(filepath.Dir(exe), "config.yaml"))
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			abs, err := filepath.Abs(c)
			if err != nil {
				abs = c
			}
			return abs, nil
		}
	}
	return "", errf(
		"no config file found (looked for --config, $MYSQLQ_CONFIG, ./config.yaml, ../config.yaml, <exe dir>/config.yaml); " +
			"create a config.yaml or pass --config <path>")
}

func checkPath(p, source string) (string, error) {
	st, err := os.Stat(p)
	if err != nil {
		if os.IsNotExist(err) {
			return "", errf("config file %q (from %s) does not exist; pass --config <path> to point at a valid config.yaml", p, source)
		}
		return "", errf("cannot access config file %q (from %s): %v", p, source, err)
	}
	if st.IsDir() {
		return "", errf("config path %q (from %s) is a directory, not a file", p, source)
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return p, nil
	}
	return abs, nil
}

// parseFile 读取并解析扁平 YAML 子集。
func parseFile(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, errf("cannot read config file %q: %v", path, err)
	}
	kv := make(map[string]string)
	for i, raw := range strings.Split(strings.TrimPrefix(string(data), "\uFEFF"), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue // 空行与整行注释
		}
		idx := strings.Index(line, ":")
		if idx < 0 {
			return nil, errf("invalid config line %d in %s: expected `key: value`, got %q", i+1, path, line)
		}
		key := strings.ToLower(strings.TrimSpace(line[:idx]))
		val := stripQuotes(strings.TrimSpace(line[idx+1:]))
		if key == "" {
			return nil, errf("invalid config line %d in %s: empty key", i+1, path)
		}
		// 注意：值中间的 `#` 不当作注释（避免密码被截断），所以这里不做行内注释剥离。
		kv[key] = val
	}
	return kv, nil
}

// stripQuotes 去掉成对的单/双引号（只在首尾同字符时去掉）。
func stripQuotes(v string) string {
	if len(v) >= 2 {
		if (v[0] == '\'' && v[len(v)-1] == '\'') || (v[0] == '"' && v[len(v)-1] == '"') {
			return v[1 : len(v)-1]
		}
	}
	return v
}
