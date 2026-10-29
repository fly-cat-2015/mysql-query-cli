// mysqlq — MySQL 只读查询 CLI。
// main 保持极薄：只负责把 argv / 标准流交给 internal/cli，并把退出码交给操作系统。
package main

import (
	"os"

	"mysql-query-cli/internal/cli"
)

func main() {
	os.Exit(cli.Execute(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}
