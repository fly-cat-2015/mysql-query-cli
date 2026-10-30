package cli

import (
	"fmt"
	"io"
)

// printUsage 打印帮助/用法（stdout：显式 --help 与缺命令时都打印到 stdout）。
func printUsage(w io.Writer) {
	fmt.Fprintf(w, `mysqlq %s — read-only MySQL query CLI

Usage:
  mysqlq [global flags] <command> [arguments]

Commands:
  info                     connection info, server version, read-only status
  databases, dbs           list databases (--all includes system schemas)
  tables [--all]           list tables/views in the current database
  columns <table>          column definitions
  indexes <table>          index definitions
  ddl <table>              SHOW CREATE TABLE output
  schema <table>           columns + indexes + ddl in one view
  query <sql>              run one read-only SQL statement ("-" reads stdin)
  explain <sql>            show the EXPLAIN plan for one read-only statement
                           ("-" reads stdin)
  find <keyword>           search table/column names and comments (substring match;
                           include %% or _ in the keyword to use it as a LIKE pattern)
  version                  print tool version

Global flags (may appear before or after the command):
  -c, --config <path>      config file (default: config.yaml next to mysqlq.exe,
                           then ./config.yaml)
      --db <name>          override the database name
      --format <fmt>       output format: table|json|csv|md (default table)
      --timeout <dur>      query timeout, e.g. 10s, 500ms, 2m (default 30s)
      --max-rows <n>       max rows returned, 1..100 (default 20 or config max_rows)
      --all                include system schemas / all objects where applicable
  -h, --help               show this help

Read-only protection:
  Only SELECT / WITH / SHOW / DESC / DESCRIBE / EXPLAIN statements are allowed.
  Write statements are blocked before any connection is made and exit with code 3.
  Execution is additionally guarded by a session-level READ ONLY setting, a
  read-only transaction, multiStatements=false, a query timeout and a row cap.

Exit codes:
  0  success
  1  runtime or config error (connection failure, SQL error, missing table, ...)
  2  usage error (unknown command, missing/invalid argument)
  3  blocked by the read-only guard (write statement)
`, Version)
}
