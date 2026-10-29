//go:build defensecheck

// 这个测试用 `-tags defensecheck` 显式开启（默认 `go test ./...` 不跑），
// 目的是用真实 MySQL 证明"绕过词法 guard 之后，服务端只读防线仍然拒绝写入"。
// 运行：go test -tags defensecheck ./internal/db -run TestServerReadOnlyDefense -v
package db

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"mysql-query-cli/internal/config"
)

func TestServerReadOnlyDefense(t *testing.T) {
	cfgPath := os.Getenv("MYSQLQ_CONFIG")
	if cfgPath == "" {
		cfgPath = "../../config.yaml"
	}
	if _, err := os.Stat(cfgPath); err != nil {
		t.Skipf("no config file at %s: %v", cfgPath, err)
	}
	cfg, err := config.Load(cfgPath, "")
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	ctx := context.Background()
	d, err := Open(ctx, *cfg, 10*time.Second)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer func() { _ = d.Close() }()

	// 这些语句完全绕过 guard.Check，直接进入只读事务；
	// MySQL 必须用 1792 "Cannot execute statement in a READ ONLY transaction" 拒绝。
	writes := []string{
		"INSERT INTO sale_pay (id, user_id, trade_no, trade_type, pay_type, pay_amount, payment_handling_fee, total_pay_amount, pay_status, pay_expire_time) VALUES (999999,1,'DEFENSE','t','p',1,0,1,'1','2030-01-01 00:00:00')",
		"UPDATE sale_pay SET pay_status = 'DEFENSE' WHERE id = 2282",
		"DELETE FROM sale_pay WHERE id = 2282",
		"CREATE TABLE zz_defense_probe (id INT)",
		"DROP TABLE sale_pay",
		"TRUNCATE sale_pay",
	}
	for _, sqlText := range writes {
		_, err := d.Query(ctx, sqlText, 10)
		if err == nil {
			t.Fatalf("server accepted a write statement: %s", sqlText)
		}
		low := strings.ToLower(err.Error())
		if !strings.Contains(low, "read only") && !strings.Contains(low, "read-only") {
			t.Fatalf("write rejected with unexpected error (want READ ONLY): %v", err)
		}
		t.Logf("rejected as expected: %s -> %v", sqlText, err)
	}

	// 数据未被修改：sale_pay=2，after_sale_reason=11。
	if v, err := d.ScalarArgs(ctx, "SELECT COUNT(*) FROM sale_pay"); err != nil || v != "2" {
		t.Fatalf("sale_pay count = %q, err = %v; want 2", v, err)
	}
	if v, err := d.ScalarArgs(ctx, "SELECT COUNT(*) FROM after_sale_reason"); err != nil || v != "11" {
		t.Fatalf("after_sale_reason count = %q, err = %v; want 11", v, err)
	}
	exists, err := d.TableExists(ctx, "zz_defense_probe")
	if err != nil || exists {
		t.Fatalf("zz_defense_probe exists = %v, err = %v; want false", exists, err)
	}
}
