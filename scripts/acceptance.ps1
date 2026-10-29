# Lead independent acceptance test for mysqlq.
# Focus: every write/DDL statement must be blocked (exit 3) and must not change the DB.
# Usage: pwsh -NoProfile -File .\scripts\acceptance.ps1 [-Binary .\bin\mysqlq.exe]
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 misreads UTF-8 without BOM.
param(
    [string]$Binary = '.\bin\mysqlq.exe',
    [string]$Config = '.\config.yaml'
)

$ErrorActionPreference = 'Continue'
$script:failures = 0
$script:checks = 0

function Invoke-MQ {
    param([string[]]$Arguments)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        # Call operator (not Start-Process): arguments are passed verbatim, so SQL
        # containing spaces/quotes is not split into several arguments.
        & $Binary @Arguments > $outFile 2> $errFile
        $code = $LASTEXITCODE
        $out = Get-Content -Raw -Path $outFile -ErrorAction SilentlyContinue
        $err = Get-Content -Raw -Path $errFile -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Exit = $code; Out = "$out"; Err = "$err" }
    }
    finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MQJson {
    param([string[]]$Arguments)
    $r = Invoke-MQ $Arguments
    # Windows PowerShell 5.1's ConvertFrom-Json emits a JSON array as ONE pipeline
    # object, so normalize explicitly instead of wrapping with @(...).
    $rows = @()
    try {
        $parsed = $r.Out | ConvertFrom-Json
        if ($null -ne $parsed) {
            if ($parsed -is [System.Array]) { $rows = $parsed } else { $rows = @($parsed) }
        }
    } catch { $rows = @() }
    return [pscustomobject]@{ Exit = $r.Exit; Out = $r.Out; Err = $r.Err; Rows = $rows }
}

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:checks++
    if ($Ok) { Write-Host ("PASS  {0}" -f $Name) -ForegroundColor Green }
    else {
        $script:failures++
        Write-Host ("FAIL  {0}  {1}" -f $Name, $Detail) -ForegroundColor Red
    }
}

if (-not (Test-Path $Binary)) { Write-Host "binary not found: $Binary" -ForegroundColor Red; exit 2 }
$Binary = (Resolve-Path $Binary).Path
$Config = (Resolve-Path $Config).Path

Write-Host "=== mysqlq acceptance ==="
Write-Host "binary: $Binary"
Write-Host "config: $Config"

# ---------- 0. baseline ----------
$tablesBefore = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()', '--format', 'json')).Rows[0].c
$payBefore = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM sale_pay', '--format', 'json')).Rows[0].c
$reasonBefore = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM after_sale_reason', '--format', 'json')).Rows[0].c
Write-Host ("baseline: tables={0} sale_pay={1} after_sale_reason={2}" -f $tablesBefore, $payBefore, $reasonBefore)

# ---------- 1. write-statement block matrix ----------
$blocked = @(
    @{ n = 'INSERT'; s = 'INSERT INTO sale_pay (id) VALUES (1)' }
    @{ n = 'INSERT mixed case/spaces'; s = '  InSeRt    INTO sale_pay (id) VALUES (1)' }
    @{ n = 'UPDATE'; s = 'UPDATE sale_pay SET amount = 0 WHERE id = 1' }
    @{ n = 'DELETE'; s = 'DELETE FROM sale_pay WHERE id = 1' }
    @{ n = 'REPLACE'; s = 'REPLACE INTO sale_pay (id) VALUES (1)' }
    @{ n = 'CREATE TABLE'; s = 'CREATE TABLE zz_probe (id INT)' }
    @{ n = 'ALTER TABLE'; s = 'ALTER TABLE sale_pay ADD COLUMN zz INT' }
    @{ n = 'DROP TABLE'; s = 'DROP TABLE sale_pay' }
    @{ n = 'TRUNCATE'; s = 'TRUNCATE TABLE sale_pay' }
    @{ n = 'RENAME TABLE'; s = 'RENAME TABLE sale_pay TO sale_pay_bak' }
    @{ n = 'GRANT'; s = 'GRANT SELECT ON bbc.* TO someone' }
    @{ n = 'SET READ WRITE'; s = 'SET SESSION TRANSACTION READ WRITE' }
    @{ n = 'CALL'; s = 'CALL some_proc()' }
    @{ n = 'LOAD DATA'; s = "LOAD DATA INFILE 'x' INTO TABLE sale_pay" }
    @{ n = 'multi-statement'; s = 'SELECT 1; DROP TABLE sale_pay' }
    @{ n = 'select-then-write'; s = 'SELECT 1; DELETE FROM sale_pay' }
    @{ n = 'block comment prefix'; s = '/*x*/ INSERT INTO sale_pay (id) VALUES (1)' }
    @{ n = 'line comment then write'; s = "-- hi`nDROP TABLE sale_pay" }
    @{ n = 'versioned comment'; s = '/*!50000 DROP TABLE sale_pay */' }
    @{ n = 'CTE delete'; s = 'WITH a AS (SELECT 1) DELETE FROM sale_pay' }
    @{ n = 'CTE update'; s = 'WITH a AS (SELECT 1) UPDATE sale_pay SET amount = 0' }
    @{ n = 'INTO OUTFILE'; s = "SELECT 1 INTO OUTFILE 'C:/tmp/zz.txt'" }
    @{ n = 'FOR UPDATE'; s = 'SELECT * FROM sale_pay FOR UPDATE' }
    @{ n = 'LOCK IN SHARE MODE'; s = 'SELECT * FROM sale_pay LOCK IN SHARE MODE' }
    @{ n = 'EXPLAIN UPDATE'; s = 'EXPLAIN UPDATE sale_pay SET amount = 0' }
    @{ n = 'empty statement'; s = '   ' }
    @{ n = 'semicolon only'; s = ';' }
    @{ n = 'TABLE shorthand'; s = 'TABLE sale_pay' }
    @{ n = 'USE db'; s = 'USE mysql' }
)

foreach ($c in $blocked) {
    # "--" terminator: SQL is positional even when it starts with "-" (e.g. a leading comment).
    $r = Invoke-MQ @('--config', $Config, 'query', '--', $c.s)
    $ok = ($r.Exit -eq 3) -and ($r.Out.Trim().Length -eq 0) -and ($r.Err -match 'blocked')
    Check ("blocked: {0}" -f $c.n) $ok ("exit={0} out='{1}' err='{2}'" -f $r.Exit, $r.Out.Trim(), $r.Err.Trim())
}

# Comments must not trigger false positives: write keywords inside strings/comments are data, not SQL.
$rj = Invoke-MQJson @('--config', $Config, '--format', 'json', 'query', '--', 'SELECT 1 AS ok -- DROP TABLE sale_pay')
Check 'write keyword in trailing comment allowed' ($rj.Exit -eq 0 -and $rj.Rows[0].ok -eq 1) ("exit={0} err={1}" -f $rj.Exit, $rj.Err.Trim())
$rc = Invoke-MQJson @('--config', $Config, '--format', 'json', 'query', '--', "-- leading comment`nSELECT 2 AS n")
Check 'leading comment then SELECT allowed' ($rc.Exit -eq 0 -and $rc.Rows[0].n -eq 2) ("exit={0} err={1}" -f $rc.Exit, $rc.Err.Trim())

# ---------- 2. integrity after blocked attempts ----------
$tablesAfter = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE()', '--format', 'json')).Rows[0].c
$payAfter = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM sale_pay', '--format', 'json')).Rows[0].c
$reasonAfter = (Invoke-MQJson @('--config', $Config, 'query', 'SELECT COUNT(*) AS c FROM after_sale_reason', '--format', 'json')).Rows[0].c
$zz = (Invoke-MQJson @('--config', $Config, 'query', "SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'zz_probe'", '--format', 'json')).Rows[0].c
Check 'integrity: table count unchanged' ($tablesAfter -eq $tablesBefore) ("before={0} after={1}" -f $tablesBefore, $tablesAfter)
Check 'integrity: sale_pay rows unchanged' ($payAfter -eq $payBefore) ("before={0} after={1}" -f $payBefore, $payAfter)
Check 'integrity: after_sale_reason rows unchanged' ($reasonAfter -eq $reasonBefore) ("before={0} after={1}" -f $reasonBefore, $reasonAfter)
Check 'integrity: no zz_probe table created' ($zz -eq 0)
Check 'integrity: sale_pay_bak not created' ((Invoke-MQJson @('--config', $Config, 'query', "SELECT COUNT(*) AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'sale_pay_bak'", '--format', 'json')).Rows[0].c -eq 0)

# ---------- 3. normal queries must still work ----------
$r = Invoke-MQ @('--config', $Config, 'info')
Check 'info exit 0 and shows 8.0.33' ($r.Exit -eq 0 -and $r.Out -match '8\.0\.33') ("exit={0} out={1}" -f $r.Exit, $r.Out.Trim())
Check 'info does not leak password' ($r.Out -notmatch 'db_passwd:\s*root' -and $r.Out -notmatch 'root:root@')

$rj = Invoke-MQJson @('--config', $Config, 'tables', '--format', 'json')
Check 'tables json has >= 12 rows' ($rj.Exit -eq 0 -and $rj.Rows.Count -ge 12) ("exit={0} rows={1}" -f $rj.Exit, $rj.Rows.Count)

$rj = Invoke-MQJson @('--config', $Config, 'columns', 'sale_pay', '--format', 'json')
Check 'columns sale_pay has rows' ($rj.Exit -eq 0 -and $rj.Rows.Count -gt 3) ("exit={0} rows={1}" -f $rj.Exit, $rj.Rows.Count)

$r = Invoke-MQ @('--config', $Config, 'indexes', 'sale_pay')
Check 'indexes sale_pay exit 0' ($r.Exit -eq 0) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())

$r = Invoke-MQ @('--config', $Config, 'ddl', 'sale_pay')
Check 'ddl sale_pay contains CREATE TABLE' ($r.Exit -eq 0 -and $r.Out -match 'CREATE TABLE') ("exit={0}" -f $r.Exit)

$r = Invoke-MQ @('--config', $Config, 'schema', 'sale_pay', '--format', 'json')
$schemaOk = $false
try {
    $s = $r.Out | ConvertFrom-Json
    $schemaOk = ($r.Exit -eq 0) -and (@($s.columns).Count -gt 0) -and ($s.ddl -match 'CREATE TABLE')
} catch {}
Check 'schema json object with columns+ddl' $schemaOk ("exit={0}" -f $r.Exit)

$r = Invoke-MQ @('--config', $Config, 'find', 'order', '--format', 'json')
Check 'find order exit 0' ($r.Exit -eq 0) ("exit={0}" -f $r.Exit)

$rj = Invoke-MQJson @('--config', $Config, 'query', 'SELECT 1 AS ok', '--format', 'json')
Check 'query SELECT 1 -> 1' ($rj.Exit -eq 0 -and $rj.Rows[0].ok -eq 1) ("exit={0} out={1}" -f $rj.Exit, $rj.Out.Trim())

$r = Invoke-MQ @('--config', $Config, 'query', "SELECT 'DELETE FROM sale_pay' AS msg, 2 AS n", '--format', 'json')
Check 'string literal with write keyword allowed' ($r.Exit -eq 0) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())

$r = Invoke-MQ @('--config', $Config, 'query', 'SELECT `id` FROM `sale_pay` LIMIT 1', '--format', 'json')
Check 'backticked identifiers allowed' ($r.Exit -eq 0) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())

# ---------- 4. exit codes ----------
$r = Invoke-MQ @('--config', $Config, 'nope')
Check 'unknown command exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)
$r = Invoke-MQ @('--config', $Config, 'columns', 'no_such_table_xyz')
Check 'missing table exit 1' ($r.Exit -eq 1) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())
$r = Invoke-MQ @('--config', $Config, 'query', 'SELECT * FROM no_such_table_xyz')
Check 'bad SQL exit 1' ($r.Exit -eq 1) ("exit={0}" -f $r.Exit)
$r = Invoke-MQ @('--config', $Config, 'tables', '--format', 'xml')
Check 'bad format exit 2' ($r.Exit -eq 2) ("exit={0}" -f $r.Exit)

# ---------- 5. row cap: default 20 / config adjustable / hard cap 100 ----------
$rj = Invoke-MQJson @('--config', $Config, 'query', 'SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS', '--format', 'json')
Check 'default max rows = 20' ($rj.Exit -eq 0 -and $rj.Rows.Count -eq 20 -and $rj.Err -match 'trunc') ("exit={0} rows={1} err={2}" -f $rj.Exit, $rj.Rows.Count, $rj.Err.Trim())

$rj = Invoke-MQJson @('--config', $Config, 'query', 'SELECT * FROM after_sale_reason', '--format', 'json', '--max-rows', '5')
Check 'max-rows 5 returns 5 and truncates' ($rj.Exit -eq 0 -and $rj.Rows.Count -eq 5 -and $rj.Err -match 'trunc') ("exit={0} rows={1}" -f $rj.Exit, $rj.Rows.Count)

$rj = Invoke-MQJson @('--config', $Config, 'query', 'SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS', '--format', 'json', '--max-rows', '100')
Check 'max-rows 100 returns 100' ($rj.Exit -eq 0 -and $rj.Rows.Count -eq 100) ("exit={0} rows={1}" -f $rj.Exit, $rj.Rows.Count)

$r = Invoke-MQ @('--config', $Config, 'query', 'SELECT 1', '--max-rows', '101')
Check 'max-rows 101 rejected exit 2' ($r.Exit -eq 2) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())
$r = Invoke-MQ @('--config', $Config, 'query', 'SELECT 1', '--max-rows', '0')
Check 'max-rows 0 rejected exit 2' ($r.Exit -eq 2) ("exit={0} err={1}" -f $r.Exit, $r.Err.Trim())

$cfg5 = [System.IO.Path]::GetTempFileName() + '.yaml'
try {
    ((Get-Content -Raw $Config) + "`nmax_rows: 5`n") | Set-Content -Path $cfg5 -Encoding ASCII
    $rj = Invoke-MQJson @('--config', $cfg5, 'query', 'SELECT * FROM after_sale_reason', '--format', 'json')
    Check 'config max_rows 5 honored' ($rj.Exit -eq 0 -and $rj.Rows.Count -eq 5) ("exit={0} rows={1} err={2}" -f $rj.Exit, $rj.Rows.Count, $rj.Err.Trim())
}
finally { Remove-Item $cfg5 -Force -ErrorAction SilentlyContinue }

$cfg500 = [System.IO.Path]::GetTempFileName() + '.yaml'
try {
    ((Get-Content -Raw $Config) + "`nmax_rows: 500`n") | Set-Content -Path $cfg500 -Encoding ASCII
    $rj = Invoke-MQJson @('--config', $cfg500, 'query', 'SELECT TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS', '--format', 'json')
    Check 'config max_rows 500 clamped to 100 + warning' ($rj.Exit -eq 0 -and $rj.Rows.Count -eq 100 -and $rj.Err -match 'warning') ("exit={0} rows={1} err={2}" -f $rj.Exit, $rj.Rows.Count, $rj.Err.Trim())
    $r = Invoke-MQ @('--config', $cfg500, 'info')
    Check 'info shows effective max_rows 100' ($r.Exit -eq 0 -and $r.Out -match '100') ("exit={0}" -f $r.Exit)
}
finally { Remove-Item $cfg500 -Force -ErrorAction SilentlyContinue }

# ---------- 6. csv / md ----------
$r = Invoke-MQ @('--config', $Config, 'tables', '--format', 'csv')
Check 'csv has header' ($r.Exit -eq 0 -and $r.Out -match 'TABLE') ("exit={0}" -f $r.Exit)
$r = Invoke-MQ @('--config', $Config, 'tables', '--format', 'md')
Check 'md table present' ($r.Exit -eq 0 -and $r.Out -match '\|\s*TABLE') ("exit={0}" -f $r.Exit)

Write-Host ''
Write-Host ("RESULT: {0} checks, {1} failure(s)" -f $script:checks, $script:failures)
if ($script:failures -gt 0) { exit 1 } else { Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green; exit 0 }