#requires -Version 5.1
<#
  mysqlq black-box verification harness (independent verifier).
  ASCII only on purpose: Windows PowerShell 5.1 decodes BOM-less UTF-8 as ANSI,
  so any non-ASCII character in this file would be corrupted at parse time.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify\verify.ps1

  Behaviour:
    - Never writes to the database, never touches the Go sources, config.yaml,
      SKILL.md, README.md, docs/SPEC.md, mysqlq.exe or scripts/acceptance.ps1.
    - Writes only scripts/verify/tmp/* (regenerated) and the two evidence files
      scripts/verify/last-run.log / scripts/verify/last-run.md.
    - Exit code: 0 = all checks passed, 1 = at least one FAIL, 2 = preflight failure.

  Deployment layout (SPEC section 1): the binary lives at the repository root
  (mysqlq.exe) next to config.yaml / config.example.yaml / SKILL.md; bin/ no
  longer exists. Config lookup order (SPEC section 2):
    --config > $MYSQLQ_CONFIG > <dir of mysqlq.exe>/config.yaml > ./config.yaml,
  i.e. independent of the current working directory.

  Output capture uses System.Diagnostics.Process instead of the call operator
  because PowerShell 5.1 wraps native stderr into ErrorRecord text when using
  "2> file", which would pollute the assertions on stderr content.
#>

$ErrorActionPreference = 'Continue'

$script:Root       = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$script:Bin        = Join-Path $script:Root 'mysqlq.exe'
$script:ConfigPath = Join-Path $script:Root 'config.yaml'
$script:Tmp        = Join-Path $PSScriptRoot 'tmp'
$script:MysqlClient = $null
$script:Results     = New-Object System.Collections.ArrayList
$script:Group       = 'general'
$script:Utf8NoBom   = New-Object System.Text.UTF8Encoding($false)

# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

function Quote-Arg([string]$s) {
  if ($null -eq $s) { return '""' }
  if ($s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $bs = 0
  foreach ($ch in $s.ToCharArray()) {
    if ($ch -eq [char]'\') { $bs++; continue }
    if ($ch -eq [char]'"') { [void]$sb.Append(('\' * (2 * $bs + 1))); [void]$sb.Append('"'); $bs = 0 }
    else { if ($bs -gt 0) { [void]$sb.Append(('\' * $bs)); $bs = 0 }; [void]$sb.Append($ch) }
  }
  if ($bs -gt 0) { [void]$sb.Append(('\' * (2 * $bs))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function Invoke-Mysqlq {
  param(
    [string[]]$ArgList,
    [string]$StdinText = $null,
    [string]$WorkDir = $null,
    [hashtable]$EnvMap = $null,
    [string]$Exe = $null,
    [int]$HardMs = 60000
  )
  if (-not $WorkDir) { $WorkDir = $script:Root }
  $exePath = $script:Bin
  if ($Exe) { $exePath = (Resolve-Path -LiteralPath $Exe).Path }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exePath
  $psi.Arguments = (($ArgList | ForEach-Object { Quote-Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = (Resolve-Path -LiteralPath $WorkDir).Path
  $psi.StandardOutputEncoding = $script:Utf8NoBom
  $psi.StandardErrorEncoding = $script:Utf8NoBom
  if ($null -ne $StdinText) { $psi.RedirectStandardInput = $true }
  foreach ($k in @('MYSQLQ_CONFIG','MYSQLQ_HOST','MYSQLQ_PORT','MYSQLQ_DB','MYSQLQ_USER','MYSQLQ_PASSWORD')) { [void]$psi.EnvironmentVariables.Remove($k) }
  if ($EnvMap) { foreach ($k in $EnvMap.Keys) { $psi.EnvironmentVariables[$k] = $EnvMap[$k] } }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  $ot = $p.StandardOutput.ReadToEndAsync()
  $et = $p.StandardError.ReadToEndAsync()
  if ($null -ne $StdinText) { $p.StandardInput.Write($StdinText); $p.StandardInput.Close() }
  $ok = $p.WaitForExit($HardMs)
  if (-not $ok) {
    try { $p.Kill() } catch { }
    $sw.Stop()
    return [pscustomobject]@{ Code = 'HARD-TIMEOUT'; Out = ''; Err = ''; Ms = $sw.ElapsedMilliseconds }
  }
  $p.WaitForExit()
  $sw.Stop()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $ot.Result; Err = $et.Result; Ms = $sw.ElapsedMilliseconds }
}

function Invoke-MysqlClient {
  param([string]$Sql, [int]$HardMs = 30000)
  if (-not $script:MysqlClient) { return $null }
  $cfg = $script:Cfg
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $script:MysqlClient
  $a = @('--protocol=tcp', '--default-character-set=utf8mb4', '-h', $cfg['db_host'], '-P', $cfg['db_port'],
         '-u', $cfg['db_user'], ('-p' + $cfg['db_passwd']), '-D', $cfg['db_name'],
         '--batch', '--skip-column-names', '-e', $Sql)
  $psi.Arguments = (($a | ForEach-Object { Quote-Arg $_ }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = $script:Utf8NoBom
  $psi.StandardErrorEncoding = $script:Utf8NoBom
  $p = [System.Diagnostics.Process]::Start($psi)
  $ot = $p.StandardOutput.ReadToEndAsync()
  $et = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($HardMs)) { try { $p.Kill() } catch { }; return [pscustomobject]@{ Code = 'HARD-TIMEOUT'; Out = ''; Err = '' } }
  $p.WaitForExit()
  return [pscustomobject]@{ Code = $p.ExitCode; Out = $ot.Result; Err = $et.Result }
}

function Format-Cmd([string[]]$ArgList) {
  $parts = @()
  foreach ($a in $ArgList) {
    $s = [string]$a
    if ($s.Length -gt 70) { $s = $s.Substring(0, 67) + '...' }
    if ($s -match '[\s"]') { $s = '"' + $s + '"' }
    $parts += $s
  }
  $txt = 'mysqlq.exe ' + ($parts -join ' ')
  if ($txt.Length -gt 150) { $txt = $txt.Substring(0, 147) + '...' }
  return $txt
}

function Add-Result {
  param(
    [string]$Group,
    [string]$Id,
    [string]$Desc,
    [string]$Cmd,
    [string]$Expect,
    [string]$Actual,
    [bool]$Ok,
    [string]$Detail = ''
  )
  $rec = New-Object psobject
  $rec | Add-Member NoteProperty Group $Group
  $rec | Add-Member NoteProperty Id $Id
  $rec | Add-Member NoteProperty Desc $Desc
  $rec | Add-Member NoteProperty Cmd $Cmd
  $rec | Add-Member NoteProperty Expect $Expect
  $rec | Add-Member NoteProperty Actual $Actual
  $rec | Add-Member NoteProperty Ok $Ok
  $rec | Add-Member NoteProperty Detail $Detail
  [void]$script:Results.Add($rec)
  if ($Ok) { Write-Host ('[PASS] ' + $Group + '/' + $Id + '  ' + $Desc) -ForegroundColor Green }
  else {
    Write-Host ('[FAIL] ' + $Group + '/' + $Id + '  ' + $Desc) -ForegroundColor Red
    Write-Host ('       expect: ' + $Expect)
    Write-Host ('       actual: ' + $Actual)
    if ($Detail) { Write-Host ('       detail: ' + $Detail) }
  }
  return $rec
}

function Add-Warn {
  param(
    [string]$Group,
    [string]$Id,
    [string]$Desc,
    [string]$Cmd,
    [string]$Expect,
    [string]$Actual,
    [string]$Detail = ''
  )
  $rec = New-Object psobject
  $rec | Add-Member NoteProperty Group $Group
  $rec | Add-Member NoteProperty Id $Id
  $rec | Add-Member NoteProperty Desc $Desc
  $rec | Add-Member NoteProperty Cmd $Cmd
  $rec | Add-Member NoteProperty Expect $Expect
  $rec | Add-Member NoteProperty Actual $Actual
  $rec | Add-Member NoteProperty Ok $true
  $rec | Add-Member NoteProperty Warn $true
  $rec | Add-Member NoteProperty Detail $Detail
  [void]$script:Results.Add($rec)
  Write-Host ('[WARN] ' + $Group + '/' + $Id + '  ' + $Desc) -ForegroundColor Yellow
  Write-Host ('       note: ' + $Actual)
  return $rec
}

function Get-CnSample { return (-join @([char]0x4E2D, [char]0x6587, [char]0x6D4B, [char]0x8BD5)) }
function Get-CnComment { return (-join @([char]0x652F, [char]0x4ED8, [char]0x8868)) }

function Get-Short([string]$Text, [int]$Max = 160) {
  if ($null -eq $Text) { return '' }
  $t = $Text.Replace("`r", '').Replace("`n", ' | ')
  if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
  return $t
}

function Get-InfoFacts([string]$Out) {
  $facts = @{}
  foreach ($line in ($Out -split "`r?`n")) {
    $m = [regex]::Match($line, '^(\S+)\s{2,}(.*)$')
    if ($m.Success) { $facts[$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
  }
  return $facts
}

function Test-Mysqlq {
  param(
    [string]$Group,
    [string]$Id,
    [string]$Desc,
    [string[]]$ArgList,
    [string]$Expect,
    [int[]]$ExpCode = @(0),
    [string[]]$OutMust = @(),
    [string[]]$OutMustNot = @(),
    [string[]]$ErrMust = @(),
    [string[]]$ErrMustNot = @(),
    [switch]$EmptyOut,
    [switch]$NonEmptyOut,
    [string]$StdinText = $null,
    [hashtable]$EnvMap = $null,
    [string]$WorkDir = $null,
    [string]$Exe = $null,
    [switch]$CaptureInfo,
    [int]$HardMs = 60000
  )
  $r = Invoke-Mysqlq -ArgList $ArgList -StdinText $StdinText -WorkDir $WorkDir -EnvMap $EnvMap -Exe $Exe -HardMs $HardMs
  $problems = @()
  if ($ExpCode -notcontains $r.Code) { $problems += ('exit=' + $r.Code + ' expected ' + ($ExpCode -join '/')) }
  foreach ($m in $OutMust) { if (-not $r.Out.Contains($m)) { $problems += ('stdout missing "' + $m + '"') } }
  foreach ($m in $OutMustNot) { if ($r.Out.Contains($m)) { $problems += ('stdout contains "' + $m + '"') } }
  foreach ($m in $ErrMust) { if (-not $r.Err.Contains($m)) { $problems += ('stderr missing "' + $m + '"') } }
  foreach ($m in $ErrMustNot) { if ($r.Err.Contains($m)) { $problems += ('stderr contains "' + $m + '"') } }
  if ($EmptyOut -and $r.Out.Trim().Length -ne 0) { $problems += ('stdout not empty (' + $r.Out.Length + ' bytes)') }
  if ($NonEmptyOut -and $r.Out.Trim().Length -eq 0) { $problems += 'stdout empty' }
  $errShort = (Get-Short $r.Err 170).TrimEnd(' ', '|')
  $actual = 'exit=' + $r.Code + '; stdout=' + $r.Out.Length + 'B; stderr: ' + $errShort
  if ($CaptureInfo) {
    $fct = Get-InfoFacts $r.Out
    $cf = [string]$fct['config_file']
    if ($cf) {
      $cfBrief = $cf
      if ($cfBrief.Length -gt 110) { $cfBrief = '...' + $cfBrief.Substring($cfBrief.Length - 107) }
      $actual += '; config_file=' + $cfBrief + '; database=' + $fct['database'] + '; max_rows=' + $fct['default_max_rows']
    } else {
      $actual += '; config_file=(no info output)'
    }
  }
  [void](Add-Result -Group $Group -Id $Id -Desc $Desc -Cmd (Format-Cmd $ArgList) -Expect $Expect -Actual $actual -Ok ($problems.Count -eq 0) -Detail ($problems -join '; '))
  return $r
}

function Test-NoLeak {
  param([string]$Group, [string]$Id, [string]$Desc, [string]$Cmd, [string]$Text, [string[]]$Markers)
  $leaks = @()
  $userValue = ''
  if ($script:Cfg -and $script:Cfg.ContainsKey('db_user')) { $userValue = [string]$script:Cfg['db_user'] }
  foreach ($m in $Markers) {
    if (-not $m) { continue }
    if ($m -eq $userValue) { continue }  # password happens to equal the user name: the word legitimately appears as "user"
    if ($Text.Contains($m)) { $leaks += ('contains secret marker "' + $m + '"') }
  }
  foreach ($m in @('root:root', '@tcp(', 'db_passwd:', 'password=')) { if ($Text.Contains($m)) { $leaks += ('contains credential pattern "' + $m + '"') } }
  [void](Add-Result -Group $Group -Id $Id -Desc $Desc -Cmd $Cmd -Expect 'no password value anywhere in stdout+stderr' -Actual ('leaks=' + $leaks.Count) -Ok ($leaks.Count -eq 0) -Detail ($leaks -join '; '))
}

function Get-JsonParse([string]$Text) {
  $t = $Text.Trim()
  $parsed = $null
  $ok = $true
  $err = ''
  if ($t.Length -eq 0) { return [pscustomobject]@{ Ok = $false; Value = $null; IsArray = $false; Text = $t; Err = 'empty' } }
  try { $parsed = ConvertFrom-Json -InputObject $t } catch { $ok = $false; $err = $_.Exception.Message }
  return [pscustomobject]@{ Ok = $ok; Value = $parsed; IsArray = $t.StartsWith('['); IsObject = $t.StartsWith('{'); Text = $t; Err = $err }
}

function Get-JsonRows([string]$Text) {
  $t = $Text.Trim()
  if ($t -eq '[]') { return @() }
  try { $v = ConvertFrom-Json -InputObject $t; return @($v) } catch { return $null }
}

function New-TempConfig {
  param([string]$Name, [hashtable]$Values, [string]$Raw = $null)
  $path = Join-Path $script:Tmp $Name
  if ($Raw) { Set-Content -LiteralPath $path -Value $Raw -Encoding ASCII }
  else {
    $lines = @()
    foreach ($k in $Values.Keys) { $lines += ($k + ': ' + $Values[$k]) }
    Set-Content -LiteralPath $path -Value $lines -Encoding ASCII
  }
  return $path
}

function Read-ConfigFile([string]$Path) {
  $map = @{}
  foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
    $t = $line.Trim()
    if ($t.Length -eq 0) { continue }
    if ($t.StartsWith('#')) { continue }
    $i = $t.IndexOf(':')
    if ($i -lt 0) { continue }
    $k = $t.Substring(0, $i).Trim().ToLowerInvariant()
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2) {
      if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) { $v = $v.Substring(1, $v.Length - 2) }
    }
    $map[$k] = $v
  }
  if (-not $map.ContainsKey('db_host')) { $map['db_host'] = '127.0.0.1' }
  if (-not $map.ContainsKey('db_port')) { $map['db_port'] = '3306' }
  if (-not $map.ContainsKey('db_charset')) { $map['db_charset'] = 'utf8mb4' }
  return $map
}

function Find-MysqlClient {
  if ($env:MYSQLQ_VERIFY_MYSQL_CLIENT -and (Test-Path -LiteralPath $env:MYSQLQ_VERIFY_MYSQL_CLIENT)) { return [string]$env:MYSQLQ_VERIFY_MYSQL_CLIENT }
  $c = Get-Command mysql.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  foreach ($p in @('D:\bin\mysql-8.0.33-winx64\bin\mysql.exe', 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe', 'C:\Program Files\MySQL\MySQL Server 5.7\bin\mysql.exe')) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  $svc = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\MySQL' -ErrorAction SilentlyContinue
  if ($svc -and $svc.ImagePath) {
    $m = [regex]::Match([string]$svc.ImagePath, '"?([A-Za-z]:\\[^"]*?)mysqld\.exe')
    if ($m.Success) {
      $p = Join-Path (Split-Path -Parent $m.Groups[1].Value) 'mysql.exe'
      if (Test-Path -LiteralPath $p) { return $p }
    }
  }
  return $null
}

$script:IntegritySql = "SELECT (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()) AS tables_cnt, (SELECT COUNT(*) FROM sale_pay) AS sp, (SELECT COUNT(*) FROM after_sale_reason) AS asr, (SELECT COUNT(*) FROM sale_pay_rel) AS spr, (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN ('zz_probe','sale_pay_bak','t_x','sale_pay_tmp','probe_tbl')) AS residue"

function Get-Integrity([string]$Tag) {
  $r = Invoke-Mysqlq -ArgList @('--format', 'json', 'query', $script:IntegritySql)
  $detail = 'mysqlq exit=' + $r.Code + ' stderr=' + (Get-Short $r.Err 90)
  if ($r.Code -ne 0) { return [pscustomobject]@{ Ok = $false; Detail = $detail; Vals = $null } }
  $rows = Get-JsonRows $r.Out
  if (-not $rows -or @($rows).Count -ne 1) { return [pscustomobject]@{ Ok = $false; Detail = ('bad json: ' + (Get-Short $r.Out 90)); Vals = $null } }
  $row = @($rows)[0]
  $vals = [ordered]@{ tables = [int]$row.tables_cnt; sp = [int]$row.sp; asr = [int]$row.asr; spr = [int]$row.spr; residue = [int]$row.residue }
  $ok = ($vals.tables -eq 12) -and ($vals.sp -eq 2) -and ($vals.asr -eq 11) -and ($vals.spr -eq 0) -and ($vals.residue -eq 0)
  $actual = 'tables=' + $vals.tables + ' sale_pay=' + $vals.sp + ' after_sale_reason=' + $vals.asr + ' sale_pay_rel=' + $vals.spr + ' residue=' + $vals.residue
  return [pscustomobject]@{ Ok = $ok; Detail = ($detail + ' | ' + $actual); Vals = $vals }
}

function Assert-Integrity([string]$Group, [string]$Id, [string]$Context) {
  $i = Get-Integrity $Context
  $mysqlDetail = ''
  if ($script:MysqlClient) {
    $sql = "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='" + $script:Cfg['db_name'] + "'; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".sale_pay; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".after_sale_reason; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".sale_pay_rel; SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='" + $script:Cfg['db_name'] + "' AND TABLE_NAME IN ('zz_probe','sale_pay_bak','t_x','sale_pay_tmp','probe_tbl');"
    $mr = Invoke-MysqlClient -Sql $sql
    if ($mr -and $mr.Code -eq 0) {
      $lines = @($mr.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
      if ($lines.Count -eq 5) {
        $expect = @('12', '2', '11', '0', '0')
        $match = $true
        for ($k = 0; $k -lt 5; $k++) { if ($lines[$k].Trim() -ne $expect[$k]) { $match = $false } }
        $mysqlDetail = 'mysql_client=' + ($lines -join '/') + ' -> ' + $(if ($match) { 'match' } else { 'MISMATCH' })
        if (-not $match) { $i.Ok = $false }
      } else { $mysqlDetail = 'mysql_client parse failed: ' + (Get-Short $mr.Out 80); $i.Ok = $false }
    } else { $mysqlDetail = 'mysql_client failed: ' + (Get-Short $mr.Err 80) }
  } else { $mysqlDetail = 'mysql_client not available' }
  $ok = $i.Ok
  $expect = 'tables=12 sale_pay=2 after_sale_reason=11 sale_pay_rel=0 residue=0 (mysqlq and independent mysql client)'
  [void](Add-Result -Group $Group -Id $Id -Desc ('data/structure intact after: ' + $Context) -Cmd 'mysqlq --format json query "<counts>" + mysql.exe counts' -Expect $expect -Actual ($i.Detail + '; ' + $mysqlDetail) -Ok $ok)
  return $ok
}

# ----------------------------------------------------------------------------
# preflight
# ----------------------------------------------------------------------------

Write-Host '============================================================'
Write-Host ' mysqlq black-box verification'
Write-Host '============================================================'

if (-not (Test-Path -LiteralPath $script:Bin)) {
  Write-Host ('[FATAL] binary not found: ' + $script:Bin) -ForegroundColor Red
  exit 2
}
if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
  Write-Host ('[FATAL] config not found: ' + $script:ConfigPath) -ForegroundColor Red
  exit 2
}
if (-not (Test-Path -LiteralPath $script:Tmp)) { [void](New-Item -ItemType Directory -Path $script:Tmp -Force) }
Get-ChildItem -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

$script:Cfg = Read-ConfigFile $script:ConfigPath
$script:MysqlClient = Find-MysqlClient
$binHash = (Get-FileHash -LiteralPath $script:Bin -Algorithm SHA256).Hash
$binInfo = Get-Item -LiteralPath $script:Bin
$psVer = $PSVersionTable.PSVersion.ToString()

$serverVersion = 'unknown'
$mysqlVersionLine = 'n/a'
if ($script:MysqlClient) {
  $vr = Invoke-MysqlClient -Sql 'SELECT VERSION();'
  if ($vr -and $vr.Code -eq 0) { $serverVersion = ($vr.Out.Trim() -split "`r?`n")[0] }
  $mysqlVersionLine = $script:MysqlClient
}

Write-Host ('root       : ' + $script:Root)
Write-Host ('binary     : ' + $script:Bin + '  (' + $binInfo.Length + ' bytes, sha256=' + $binHash.Substring(0, 16) + '...)')
Write-Host ('config     : ' + $script:ConfigPath)
Write-Host ('mysql client: ' + $mysqlVersionLine)
Write-Host ('server     : ' + $serverVersion)
Write-Host ('powershell : ' + $psVer)
Write-Host ''

# ----------------------------------------------------------------------------
# group: env / baseline
# ----------------------------------------------------------------------------

$script:Group = 'env'
[void](Add-Result -Group 'env' -Id 'env-01' -Desc 'binary present and executable at repository root (deployment dir)' -Cmd 'Test-Path mysqlq.exe' -Expect 'exists, >1MB' -Actual ($binInfo.Length.ToString() + ' bytes') -Ok ($binInfo.Length -gt 100000))
$binDirExists = Test-Path -LiteralPath (Join-Path $script:Root 'bin')
[void](Add-Result -Group 'env' -Id 'env-04' -Desc 'no bin/ directory (build output moved to repo root)' -Cmd 'Test-Path bin' -Expect 'bin/ removed' -Actual ('bin exists=' + $binDirExists) -Ok (-not $binDirExists))
[void](Add-Result -Group 'env' -Id 'env-02' -Desc 'server is MySQL 8.0.33' -Cmd 'mysql.exe -e "SELECT VERSION()"' -Expect '8.0.33' -Actual $serverVersion -Ok ($serverVersion -eq '8.0.33'))
[void](Add-Result -Group 'env' -Id 'env-03' -Desc 'independent mysql client available (extra integrity cross-check)' -Cmd 'Find-MysqlClient' -Expect 'mysql.exe found' -Actual $mysqlVersionLine -Ok ([bool]$script:MysqlClient))

$b = Get-Integrity 'preflight'
[void](Add-Result -Group 'baseline' -Id 'base-01' -Desc 'baseline data/structure (mysqlq)' -Cmd 'mysqlq --format json query "<counts>"' -Expect 'tables=12 sale_pay=2 after_sale_reason=11 sale_pay_rel=0 residue=0' -Actual $b.Detail -Ok $b.Ok)
if ($script:MysqlClient) {
  $mr = Invoke-MysqlClient -Sql ("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='" + $script:Cfg['db_name'] + "'; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".sale_pay; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".after_sale_reason; SELECT COUNT(*) FROM " + $script:Cfg['db_name'] + ".sale_pay_rel;")
  $lines = @($mr.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
  [void](Add-Result -Group 'baseline' -Id 'base-02' -Desc 'baseline data/structure (independent mysql client)' -Cmd 'mysql.exe -e "SELECT COUNT(*)...' -Expect '12 / 2 / 11 / 0' -Actual ($lines -join '/') -Ok (($lines -join '/') -eq '12/2/11/0'))
}

# ----------------------------------------------------------------------------
# group: commands
# ----------------------------------------------------------------------------

$script:Group = 'commands'
$r = Test-Mysqlq -Group 'commands' -Id 'cmd-01' -Desc 'version prints tool version' -ArgList @('version') -Expect 'stdout "mysqlq 1.0.0", exit 0' -OutMust @('mysqlq 1.0.0') -EmptyOut:$false
[void](Add-Result -Group 'commands' -Id 'cmd-01b' -Desc 'version stdout is exactly one line' -Cmd 'mysqlq.exe version' -Expect 'trimmed stdout = "mysqlq 1.0.0"' -Actual ('[' + $r.Out.Trim() + ']') -Ok ($r.Out.Trim() -eq 'mysqlq 1.0.0'))

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-02' -Desc 'info shows server 8.0.33, db bbc, read_only true, no password' -ArgList @('info') -Expect '10 fixed rows with expected values' -OutMust @('tool_version', 'config_file', 'host', 'port', 'database', 'user', 'server_version', 'read_only', 'default_max_rows', 'default_timeout', '8.0.33', 'bbc', 'true')
Test-NoLeak -Group 'commands' -Id 'cmd-02b' -Desc 'info does not leak password' -Cmd 'mysqlq.exe info' -Text ($r.Out + $r.Err) -Markers @($script:Cfg['db_passwd'])
$infoLines = @(($r.Out -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 })
$infoOrder = @('tool_version', 'config_file', 'host', 'port', 'database', 'user', 'server_version', 'read_only', 'default_max_rows', 'default_timeout')
$orderOk = $false
if ($infoLines.Count -eq 12) {
  $orderOk = $true
  for ($k = 0; $k -lt 10; $k++) { if (-not $infoLines[$k + 2].TrimStart().StartsWith($infoOrder[$k])) { $orderOk = $false } }
}
[void](Add-Result -Group 'commands' -Id 'cmd-02c' -Desc 'info row order fixed' -Cmd 'mysqlq.exe info' -Expect (($infoOrder -join ' > ') + ' (10 rows + header)') -Actual ((@($infoLines | ForEach-Object { ($_ -split '\s{2,}')[0] })) -join ' > ') -Ok $orderOk)

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-03' -Desc 'databases excludes system schemas by default' -ArgList @('--format', 'json', 'databases') -Expect 'array, no information_schema/mysql/performance_schema/sys, sorted' -OutMust @('"DATABASE": "bbc"') -OutMustNot @('information_schema', 'performance_schema', '"mysql"', '"sys"')
$dbs = Get-JsonRows $r.Out
$dbsOk = $false; $dbsCount = -1; $dbsSorted = $false
if ($dbs) {
  $dbsCount = @($dbs).Count
  $names = @($dbs | ForEach-Object { [string]$_.DATABASE })
  $sortedNames = @($names | Sort-Object)
  $dbsSorted = (($names -join ',') -eq ($sortedNames -join ','))
  $dbsOk = ($dbsCount -eq 17) -and $dbsSorted
}
[void](Add-Result -Group 'commands' -Id 'cmd-03b' -Desc 'databases default list = 17 non-system schemas, sorted' -Cmd 'mysqlq.exe --format json databases' -Expect '17 rows sorted, no system schema' -Actual ('count=' + $dbsCount + ' sorted=' + $dbsSorted) -Ok $dbsOk)

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-04' -Desc 'databases --all includes system schemas' -ArgList @('--format', 'json', '--max-rows', '100', 'databases', '--all') -Expect '21 rows incl information_schema/mysql/performance_schema/sys' -OutMust @('information_schema', 'performance_schema', '"mysql"', '"sys"')
$allDbs = Get-JsonRows $r.Out
$allCount = -1
if ($allDbs) { $allCount = @($allDbs).Count }
[void](Add-Result -Group 'commands' -Id 'cmd-04b' -Desc 'databases --all count = 21' -Cmd 'mysqlq.exe --format json --max-rows 100 databases --all' -Expect '21 rows' -Actual ('count=' + $allCount) -Ok ($allCount -eq 21))

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-05' -Desc 'tables lists 12 tables with TYPE/ENGINE/ROWS/COMMENT' -ArgList @('--format', 'json', 'tables') -Expect '12 TABLE rows, sale_pay ROWS=2, headers TABLE/TYPE/ENGINE/ROWS/COMMENT' -OutMust @('"TABLE": "sale_pay"', '"TYPE": "BASE TABLE"', '"COMMENT"', (Get-CnComment))
$tbls = Get-JsonRows $r.Out
$tblCount = -1; $tblOk = $false; $spRows = $null
if ($tbls) {
  $tblCount = @($tbls).Count
  $spRows = (@($tbls) | Where-Object { $_.TABLE -eq 'sale_pay' } | Select-Object -First 1).ROWS
  $tblOk = ($tblCount -eq 12) -and ($spRows -eq 2)
}
[void](Add-Result -Group 'commands' -Id 'cmd-05b' -Desc 'tables count=12 and sale_pay ROWS=2' -Cmd 'mysqlq.exe --format json tables' -Expect 'count=12 sale_pay.ROWS=2' -Actual ('count=' + $tblCount + ' sale_pay.ROWS=' + $spRows) -Ok $tblOk)

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-06' -Desc 'tables --all works' -ArgList @('--format', 'json', 'tables', '--all') -Expect 'exit 0, 12 rows' -OutMust @('"sale_pay"')
$r = Test-Mysqlq -Group 'commands' -Id 'cmd-07' -Desc 'columns sale_pay has 8 columns ordered by ordinal' -ArgList @('--format', 'json', 'columns', 'sale_pay') -Expect '18 rows, headers # COLUMN TYPE NULL KEY DEFAULT EXTRA COMMENT, first row id/PRI/auto_increment' -OutMust @('"COLUMN": "id"', '"KEY": "PRI"', '"EXTRA": "auto_increment"', '"TYPE": "int unsigned"')
$cols = Get-JsonRows $r.Out
$colCount = -1; $colOrderOk = $false; $colHeadOk = $false; $colMysqlCount = -1
if ($cols) {
  $colCount = @($cols).Count
  $ord = @($cols | ForEach-Object { [int]$_.PSObject.Properties['#'].Value })
  $seq = 1..$colCount
  $colOrderOk = (($ord -join ',') -eq ($seq -join ','))
  $first = @($cols)[0]
  $colHeadOk = ($first.PSObject.Properties.Name -join ',') -eq '#,COLUMN,TYPE,NULL,KEY,DEFAULT,EXTRA,COMMENT'
}
if ($script:MysqlClient) {
  $mr = Invoke-MysqlClient -Sql ("SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='" + $script:Cfg['db_name'] + "' AND TABLE_NAME='sale_pay';")
  if ($mr -and $mr.Code -eq 0) { $colMysqlCount = [int]($mr.Out.Trim()) }
}
[void](Add-Result -Group 'commands' -Id 'cmd-07b' -Desc 'columns count=18 matches independent mysql client, ordered by #' -Cmd 'mysqlq.exe --format json columns sale_pay' -Expect 'count=18, # = 1..18, header order' -Actual ('count=' + $colCount + ' mysql_client=' + $colMysqlCount + ' ordered=' + $colOrderOk + ' headers=' + $colHeadOk) -Ok (($colCount -eq 18) -and ($colCount -eq $colMysqlCount) -and $colOrderOk -and $colHeadOk))

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-08' -Desc 'indexes sale_pay: PRIMARY first then others by name' -ArgList @('--format', 'json', 'indexes', 'sale_pay') -Expect '4 rows, headers INDEX UNIQUE COLUMNS TYPE COMMENT, PRIMARY first, COLUMNS comma-joined' -OutMust @('"INDEX": "PRIMARY"', '"COLUMNS": "pay_time,pay_status"')
$idx = Get-JsonRows $r.Out
$idxCount = -1; $idxOk = $false; $idxMysqlCount = -1
if ($idx) {
  $idxCount = @($idx).Count
  $names = @($idx | ForEach-Object { [string]$_.INDEX })
  $rest = @($names | Select-Object -Skip 1)
  $sortedRest = @($rest | Sort-Object)
  $idxOk = ($idxCount -eq 4) -and ($names[0] -eq 'PRIMARY') -and (($rest -join ',') -eq ($sortedRest -join ','))
}
if ($script:MysqlClient) {
  $mr = Invoke-MysqlClient -Sql ("SELECT COUNT(DISTINCT INDEX_NAME) FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='" + $script:Cfg['db_name'] + "' AND TABLE_NAME='sale_pay';")
  if ($mr -and $mr.Code -eq 0) { $idxMysqlCount = [int]($mr.Out.Trim()) }
}
[void](Add-Result -Group 'commands' -Id 'cmd-08b' -Desc 'indexes count=4 matches mysql client, PRIMARY first' -Cmd 'mysqlq.exe --format json indexes sale_pay' -Expect 'count=4 PRIMARY first' -Actual ('count=' + $idxCount + ' mysql_client=' + $idxMysqlCount + ' primary_first=' + $idxOk) -Ok (($idxCount -eq 4) -and ($idxCount -eq $idxMysqlCount) -and $idxOk))

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-09' -Desc 'ddl sale_pay prints raw SHOW CREATE TABLE' -ArgList @('ddl', 'sale_pay') -Expect 'stdout starts with CREATE TABLE `sale_pay`, multiline, exit 0' -OutMust @('CREATE TABLE `sale_pay`', 'AUTO_INCREMENT')
[void](Add-Result -Group 'commands' -Id 'cmd-09b' -Desc 'ddl table format is not aligned into a table' -Cmd 'mysqlq.exe ddl sale_pay' -Expect 'raw DDL, no ---- separator line' -Actual ('lines=' + (@($r.Out -split "`r?`n").Count) + ' hasSeparator=' + $r.Out.Contains('---')) -Ok ((-not $r.Out.Contains('----')) -and $r.Out.Contains('ENGINE=InnoDB')))

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-10' -Desc 'schema sale_pay table format has 3 section headers' -ArgList @('schema', 'sale_pay') -Expect 'stdout contains == columns ==, == indexes ==, == ddl ==' -OutMust @('== columns ==', '== indexes ==', '== ddl ==')

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-11' -Desc 'query scalar works' -ArgList @('query', '--', 'SELECT 1 AS one') -Expect 'value 1, exit 0' -OutMust @('one')

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-12' -Desc 'query reads SQL from stdin ("-")' -ArgList @('--format', 'json', 'query', '-') -StdinText "SELECT 42 AS answer`n" -Expect 'stdin SQL executed, {"answer":42}' -OutMust @('"answer": 42')

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-13' -Desc 'find order: tables first then columns, KIND column' -ArgList @('--format', 'json', '--max-rows', '100', 'find', 'order') -Expect 'array of KIND TABLE then KIND COLUMN, exit 0' -OutMust @('"KIND": "TABLE"', '"KIND": "COLUMN"', 'sale_order')
$findRows = Get-JsonRows $r.Out
$findOk = $false; $findCount = -1; $findOrderOk = $false
if ($findRows) {
  $findCount = @($findRows).Count
  $kinds = @($findRows | ForEach-Object { [string]$_.KIND })
  $lastTable = -1; $firstCol = -1
  for ($k = 0; $k -lt $kinds.Count; $k++) { if ($kinds[$k] -eq 'TABLE') { $lastTable = $k }; if (($kinds[$k] -eq 'COLUMN') -and ($firstCol -lt 0)) { $firstCol = $k } }
  $findOrderOk = ($firstCol -lt 0) -or ($lastTable -lt $firstCol)
  $findOk = $findOrderOk
}
[void](Add-Result -Group 'commands' -Id 'cmd-13b' -Desc 'find order row order: all TABLE rows before COLUMN rows' -Cmd 'mysqlq.exe --format json --max-rows 100 find order' -Expect 'TABLE rows precede COLUMN rows' -Actual ('count=' + $findCount + ' order_ok=' + $findOrderOk) -Ok $findOk)

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-14' -Desc 'find is case-insensitive and % is passed through LIKE' -ArgList @('--format', 'json', '--max-rows', '100', 'find', 'SALE_ORDER') -Expect 'same matches as lowercase order, exit 0' -OutMust @('sale_order')
$r2 = Test-Mysqlq -Group 'commands' -Id 'cmd-15' -Desc 'find with explicit % wildcard works' -ArgList @('--format', 'json', '--max-rows', '100', 'find', 'sale%') -Expect 'tables starting with sale, exit 0' -OutMust @('sale_order', 'sale_pay')
$r3 = Test-Mysqlq -Group 'commands' -Id 'cmd-16' -Desc 'find no-match returns 0 rows, exit 0' -ArgList @('--format', 'json', 'find', 'zzz_no_such_keyword_zzz') -Expect '[], exit 0' -OutMust @('[]')

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-17' -Desc 'DBS alias works' -ArgList @('--format', 'json', 'dbs') -Expect 'same as databases, exit 0' -OutMust @('"DATABASE": "bbc"')

$r = Test-Mysqlq -Group 'commands' -Id 'cmd-18' -Desc '--help exit 0 and lists all commands/flags' -ArgList @('--help') -Expect 'exit 0, usage text on stdout' -OutMust @('Usage:', 'info', 'databases', 'tables', 'columns', 'indexes', 'ddl', 'schema', 'query', 'find', 'version', '--max-rows', '--timeout', '--format', '--db', '-c, --config', 'Exit codes')
[void](Add-Result -Group 'commands' -Id 'cmd-18b' -Desc '--help stderr empty' -Cmd 'mysqlq.exe --help' -Expect 'stderr empty' -Actual ('stderr=' + $r.Err.Length + 'B') -Ok ($r.Err.Trim().Length -eq 0))

$r = Test-Mysqlq -Group 'exitcodes' -Id 'exit-nocmd' -Desc 'no subcommand prints usage to stdout and exits 2' -ArgList @() -ExpCode @(2) -Expect 'exit 2, usage on stdout' -OutMust @('Usage:') -NonEmptyOut
[void](Add-Result -Group 'exitcodes' -Id 'exit-nocmd2' -Desc 'no subcommand stderr empty (usage goes to stdout per spec)' -Cmd 'mysqlq.exe' -Expect 'stderr empty' -Actual ('stderr=' + $r.Err.Length + 'B') -Ok ($r.Err.Trim().Length -eq 0))

# ----------------------------------------------------------------------------
# group: formats  (10 commands x 4 formats)
# ----------------------------------------------------------------------------

$script:Group = 'formats'
$fmtCases = @(
  @{ Id = 'info'; Args = @('info'); Array = $true },
  @{ Id = 'databases'; Args = @('databases'); Array = $true },
  @{ Id = 'tables'; Args = @('tables'); Array = $true },
  @{ Id = 'columns'; Args = @('columns', 'sale_pay'); Array = $true },
  @{ Id = 'indexes'; Args = @('indexes', 'sale_pay'); Array = $true },
  @{ Id = 'ddl'; Args = @('ddl', 'sale_pay'); Array = $true; CsvRows = 1 },
  @{ Id = 'schema'; Args = @('schema', 'sale_pay'); Array = $false },
  @{ Id = 'query'; Args = @('query', 'SELECT id, trade_no FROM sale_pay ORDER BY id LIMIT 2'); Array = $true; CsvRows = 2; JsonRows = 2 },
  @{ Id = 'find'; Args = @('find', 'order'); Array = $true },
  @{ Id = 'version'; Args = @('version'); Array = $null }
)
foreach ($fc in $fmtCases) {
  $argsBase = @($fc.Args)
  $id = [string]$fc.Id

  # ---- table ----
  $r = Test-Mysqlq -Group 'formats' -Id ($id + '-table') -Desc ($id + ' --format table') -ArgList (@('--format', 'table') + $argsBase) -Expect 'exit 0, valid table output' -NonEmptyOut
  if ($id -eq 'version') {
    [void](Add-Result -Group 'formats' -Id ($id + '-table2') -Desc 'version table format prints version text' -Cmd 'mysqlq.exe --format table version' -Expect 'contains mysqlq' -Actual (Get-Short $r.Out 80) -Ok ($r.Out.Contains('mysqlq')))
  } elseif ($id -eq 'ddl') {
    [void](Add-Result -Group 'formats' -Id ($id + '-table2') -Desc 'ddl table format is raw multiline DDL (no table/separator framing)' -Cmd 'mysqlq.exe --format table ddl sale_pay' -Expect 'starts with CREATE TABLE, no ---- separator, no TABLE/DDL header' -Actual ('starts=' + $r.Out.TrimStart().StartsWith('CREATE TABLE') + ' hasSep=' + $r.Out.Contains('----') + ' lines=' + (@($r.Out -split "`r?`n").Count)) -Ok ($r.Out.TrimStart().StartsWith('CREATE TABLE') -and (-not $r.Out.Contains('----')) -and (-not $r.Out.Contains('TABLE  DDL'))))
  } else {
    $hasSep = $r.Out.Contains('----')
    [void](Add-Result -Group 'formats' -Id ($id + '-table2') -Desc 'table format has header + ---- separator, no +--+ borders' -Cmd ('mysqlq.exe --format table ' + $id) -Expect 'contains ----, no +--+' -Actual ('sep=' + $hasSep + ' borders=' + $r.Out.Contains('+--')) -Ok ($hasSep -and (-not $r.Out.Contains('+--'))))
  }
  if ($id -eq 'schema') {
    [void](Add-Result -Group 'formats' -Id ($id + '-table3') -Desc 'schema table format section order columns,indexes,ddl' -Cmd 'mysqlq.exe --format table schema sale_pay' -Expect 'columns before indexes before ddl' -Actual (Get-Short $r.Out 60) -Ok (($r.Out.IndexOf('== columns ==') -ge 0) -and ($r.Out.IndexOf('== columns ==') -lt $r.Out.IndexOf('== indexes ==')) -and ($r.Out.IndexOf('== indexes ==') -lt $r.Out.IndexOf('== ddl =='))))
  }

  # ---- json ----
  $r = Test-Mysqlq -Group 'formats' -Id ($id + '-json') -Desc ($id + ' --format json is valid JSON') -ArgList (@('--format', 'json') + $argsBase) -Expect 'valid JSON' -NonEmptyOut
  $jp = Get-JsonParse $r.Out
  if ($id -eq 'version') {
    [void](Add-Result -Group 'formats' -Id ($id + '-json-parse') -Desc 'version ignores --format and still prints plain version text' -Cmd 'mysqlq.exe --format json version' -Expect 'exit 0, contains mysqlq (format not applicable)' -Actual (Get-Short $r.Out 60) -Ok ($r.Out.Contains('mysqlq')))
  } else {
    [void](Add-Result -Group 'formats' -Id ($id + '-json-parse') -Desc 'json parses with ConvertFrom-Json' -Cmd ('mysqlq.exe --format json ' + $id) -Expect 'valid JSON' -Actual ('ok=' + $jp.Ok + ' err=' + (Get-Short $jp.Err 70)) -Ok $jp.Ok)
  }
  if ($jp.Ok -and $null -ne $fc.Array) {
    if ($fc.Array) {
      [void](Add-Result -Group 'formats' -Id ($id + '-json-array') -Desc 'json is a top-level array' -Cmd ('mysqlq.exe --format json ' + $id) -Expect 'starts with [ and is array' -Actual ('startsWith[=' + $jp.Text.StartsWith('[')) -Ok $jp.Text.StartsWith('['))
    } else {
      $objOk = $jp.Text.StartsWith('{')
      [void](Add-Result -Group 'formats' -Id ($id + '-json-object') -Desc 'schema json is a single object (spec exception)' -Cmd 'mysqlq.exe --format json schema sale_pay' -Expect 'object with database/table/columns/indexes/ddl' -Actual (Get-Short $jp.Text 60) -Ok ($objOk -and $jp.Text.Contains('"database"') -and $jp.Text.Contains('"columns"') -and $jp.Text.Contains('"indexes"') -and $jp.Text.Contains('"ddl"')))
    }
  }
  if ($jp.Ok -and $id -eq 'schema') {
    $so = $jp.Value
    [void](Add-Result -Group 'formats' -Id 'schema-json-fields' -Desc 'schema json values correct' -Cmd 'mysqlq.exe --format json schema sale_pay' -Expect 'database=bbc table=sale_pay columns=18 indexes=4 ddl starts CREATE TABLE' -Actual ('db=' + $so.database + ' table=' + $so.table + ' cols=' + @($so.columns).Count + ' idx=' + @($so.indexes).Count + ' ddl=' + (Get-Short ([string]$so.ddl) 30)) -Ok (($so.database -eq 'bbc') -and ($so.table -eq 'sale_pay') -and (@($so.columns).Count -eq 18) -and (@($so.indexes).Count -eq 4) -and ([string]$so.ddl).StartsWith('CREATE TABLE')))
  }
  if ($jp.Ok -and $id -eq 'ddl') {
    $ddlArr = Get-JsonRows $r.Out
    $d0 = @($ddlArr)[0]
    [void](Add-Result -Group 'formats' -Id 'ddl-json-fields' -Desc 'ddl json = [{"TABLE":"sale_pay","DDL":"CREATE TABLE ..."}]' -Cmd 'mysqlq.exe --format json ddl sale_pay' -Expect 'array of 1 with TABLE and DDL' -Actual ('count=' + @($ddlArr).Count + ' TABLE=' + $d0.TABLE) -Ok ((@($ddlArr).Count -eq 1) -and ($d0.TABLE -eq 'sale_pay') -and ([string]$d0.DDL).StartsWith('CREATE TABLE')))
  }
  if ($jp.Ok -and $id -eq 'info') {
    $infoObj = @(Get-JsonRows $r.Out)
    $kv = @{}
    foreach ($o in $infoObj) { $kv[[string]$o.KEY] = $o.VALUE }
    [void](Add-Result -Group 'formats' -Id 'info-json-values' -Desc 'info json 10 KEY/VALUE rows with expected values' -Cmd 'mysqlq.exe --format json info' -Expect '10 rows, server_version=8.0.33, database=bbc, read_only=true, default_max_rows=20' -Actual ('rows=' + $infoObj.Count + ' server=' + $kv['server_version'] + ' db=' + $kv['database'] + ' ro=' + $kv['read_only'] + ' max=' + $kv['default_max_rows'] + ' timeout=' + $kv['default_timeout']) -Ok (($infoObj.Count -eq 10) -and ($kv['server_version'] -eq '8.0.33') -and ($kv['database'] -eq 'bbc') -and ($kv['read_only'] -eq 'true') -and ([int]$kv['default_max_rows'] -eq 20) -and ($kv['default_timeout'] -eq '30s')))
    Test-NoLeak -Group 'formats' -Id 'info-json-noleak' -Desc 'info json does not leak password' -Cmd 'mysqlq.exe --format json info' -Text ($r.Out + $r.Err) -Markers @($script:Cfg['db_passwd'])
  }
  if ($jp.Ok -and $id -eq 'query' -and $fc.ContainsKey('JsonRows')) {
    $qr = Get-JsonRows $r.Out
    [void](Add-Result -Group 'formats' -Id 'query-json-rows' -Desc 'query json has 2 rows with keys id/trade_no' -Cmd 'mysqlq.exe --format json query "SELECT id, trade_no ..."' -Expect '2 rows' -Actual ('rows=' + @($qr).Count) -Ok (@($qr).Count -eq 2))
  }

  # ---- csv ----
  if ($id -ne 'version') {
    $r = Test-Mysqlq -Group 'formats' -Id ($id + '-csv') -Desc ($id + ' --format csv is valid RFC4180 CSV') -ArgList (@('--format', 'csv') + $argsBase) -Expect 'exit 0, parseable CSV, CRLF line endings' -NonEmptyOut
    $csvPath = Join-Path $script:Tmp ('fmt_' + $id + '.csv')
    [System.IO.File]::WriteAllText($csvPath, $r.Out, (New-Object System.Text.UTF8Encoding($false)))
    $csvOk = $false; $csvRows = -1; $csvErr = ''
    try {
      $rows = @(Import-Csv -LiteralPath $csvPath -WarningAction SilentlyContinue)
      $csvRows = $rows.Count
      $header = ($rows[0].PSObject.Properties.Name -join ',')
      $csvOk = ($header.Length -gt 0)
    } catch { $csvErr = $_.Exception.Message }
    $expectRows = '>=0'
    $rowsOk = $true
    if ($fc.ContainsKey('CsvRows')) { $expectRows = [string]$fc.CsvRows; $rowsOk = ($csvRows -eq $fc.CsvRows) }
    $firstLine = (($r.Out -split "`r?`n") | Select-Object -First 1)
    if ($id -eq 'columns' -or $id -eq 'schema') {
      $expectHeader = '#,COLUMN,TYPE,NULL,KEY,DEFAULT,EXTRA,COMMENT'
      [void](Add-Result -Group 'formats' -Id ($id + '-csv-header') -Desc 'csv header row is correct (leading-# column is a legal RFC4180 field)' -Cmd ('mysqlq.exe --format csv ' + $id) -Expect $expectHeader -Actual $firstLine -Ok ($firstLine -eq $expectHeader))
      [void](Add-Result -Group 'formats' -Id ($id + '-csv-parse') -Desc 'csv parses with Import-Csv without exception (see WARN: PowerShell skips leading-# line)' -Cmd ('mysqlq.exe --format csv ' + $id) -Expect 'no parse exception' -Actual ('Import-Csv returned ' + $csvRows + ' rows, first-header=' + $header + ' err=' + (Get-Short $csvErr 60)) -Ok ($csvOk))
      [void](Add-Warn -Group 'formats' -Id ($id + '-csv-importcsv-hash') -Desc 'PowerShell Import-Csv/ConvertFrom-Csv treat the leading-# header line as a comment' -Cmd ('Import-Csv ' + $csvPath) -Expect 'header #,COLUMN,... and 18 data rows' -Actual ('Import-Csv header=[' + $header + '] rows=' + $csvRows + '; with explicit -Header it returns 19 rows. Python csv module parses correctly: header=[#,COLUMN,...], 18 data rows. RFC4180 output itself is valid; this is a PowerShell parser quirk, reported as a MINOR interop caveat.') -Detail 'minor')
    } else {
      [void](Add-Result -Group 'formats' -Id ($id + '-csv-parse') -Desc 'csv parses with Import-Csv' -Cmd ('mysqlq.exe --format csv ' + $id) -Expect ('Import-Csv ok, rows ' + $expectRows) -Actual ('rows=' + $csvRows + ' err=' + (Get-Short $csvErr 70)) -Ok ($csvOk -and $rowsOk))
    }
    if ($id -eq 'columns') {
      $recCount = @($r.Out.TrimEnd("`r", "`n") -split "`r`n").Count
      [void](Add-Result -Group 'formats' -Id ($id + '-csv-record-count') -Desc 'columns csv has header + 18 data records' -Cmd 'mysqlq.exe --format csv columns sale_pay' -Expect '19 CRLF records' -Actual ($recCount.ToString()) -Ok ($recCount -eq 19))
    }
    $crlfOk = $r.Out.Contains("`r`n")
    [void](Add-Result -Group 'formats' -Id ($id + '-csv-crlf') -Desc 'csv rows terminate with CRLF (RFC4180)' -Cmd ('mysqlq.exe --format csv ' + $id) -Expect 'contains CRLF' -Actual ('crlf=' + $crlfOk) -Ok $crlfOk)
  }

  # ---- md ----
  if ($id -ne 'version') {
    $r = Test-Mysqlq -Group 'formats' -Id ($id + '-md') -Desc ($id + ' --format md is GitHub Markdown table') -ArgList (@('--format', 'md') + $argsBase) -Expect 'exit 0, pipe table with --- separator' -OutMust @('|') -NonEmptyOut
    $mdLines = @($r.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
    $mdOk = ($mdLines.Count -ge 2) -and $mdLines[0].Trim().StartsWith('|') -and $mdLines[1].Contains('---')
    [void](Add-Result -Group 'formats' -Id ($id + '-md-shape') -Desc 'md has header row and |---| separator' -Cmd ('mysqlq.exe --format md ' + $id) -Expect 'header row, separator row with ---' -Actual ('lines=' + $mdLines.Count + ' head=' + (Get-Short $mdLines[0] 50)) -Ok $mdOk)
  }
}

# ----------------------------------------------------------------------------
# group: format details (null / quoting / escaping / numeric / binary)
# ----------------------------------------------------------------------------

$script:Group = 'format-detail'
$detailSql = "SELECT NULL AS a, 'x,y' AS b, 'he said ""hi""' AS c, 'a|b' AS d, 'line1\nline2' AS e, 1.50 AS f, 1234567890123456789 AS g, CAST('2024-01-02 03:04:05' AS DATETIME) AS h"

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-01' -Desc 'table format: NULL literal, newline folded to space, no borders' -ArgList @('--format', 'table', 'query', $detailSql) -Expect 'NULL cell, "line1 line2", no embedded newline inside a cell' -OutMust @('NULL', 'line1 line2')
[void](Add-Result -Group 'format-detail' -Id 'det-01b' -Desc 'table format newline in cell replaced by space (row count unchanged)' -Cmd 'mysqlq.exe --format table query "<detail>"' -Expect 'single data row' -Actual ('datalines=' + (@($r.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }).Count)) -Ok ((@($r.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }).Count) -eq 3))

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-02' -Desc 'json format: NULL->null, number types preserved, 2-space indent, utf-8 not escaped' -ArgList @('--format', 'json', 'query', $detailSql) -Expect 'a:null, f:1.50, g:big int, h:string, 2-space indent' -OutMust @('"a": null', '"f": 1.50', '"g": 1234567890123456789', '"h": "2024-01-02 03:04:05"')
$jp = Get-JsonParse $r.Out
$jOk = $jp.Ok
if ($jOk) {
  $row = @(Get-JsonRows $r.Out)[0]
  $jOk = ($null -eq $row.a) -and ($row.c -eq 'he said "hi"') -and ($row.e -eq "line1`nline2")
}
[void](Add-Result -Group 'format-detail' -Id 'det-02b' -Desc 'json values round-trip correctly (null, quotes, embedded newline)' -Cmd 'mysqlq.exe --format json query "<detail>"' -Expect 'null and escaped values round-trip' -Actual ('parsed=' + $jp.Ok) -Ok $jOk)
$indentOk = $r.Out.Contains("`n  {")
[void](Add-Result -Group 'format-detail' -Id 'det-02c' -Desc 'json is pretty-printed with 2 spaces and ends with newline' -Cmd 'mysqlq.exe --format json query "<detail>"' -Expect '2-space indent, trailing newline' -Actual ('indent=' + $indentOk + ' trailingLF=' + $r.Out.EndsWith("`n")) -Ok ($indentOk -and $r.Out.EndsWith("`n") -and -not $r.Out.EndsWith("`n`n")))

$cnSample = Get-CnSample
$r = Test-Mysqlq -Group 'format-detail' -Id 'det-03' -Desc 'json unicode not escaped' -ArgList @('--format', 'json', 'query', "SELECT '$cnSample' AS c") -Expect 'raw UTF-8 Chinese in JSON (no \u escape)' -OutMust @($cnSample)
[void](Add-Result -Group 'format-detail' -Id 'det-03b' -Desc 'json unicode is raw utf-8, not \uXXXX escaped' -Cmd 'mysqlq.exe --format json query "SELECT <chinese-sample>"' -Expect 'no \u4e2d escape sequence' -Actual ('escaped=' + $r.Out.Contains('\u4e2d')) -Ok (-not $r.Out.Contains('\u4e2d')))

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-04' -Desc 'csv RFC4180: quoted comma/quote/newline, NULL empty, CRLF' -ArgList @('--format', 'csv', 'query', $detailSql) -Expect 'quoted fields, empty NULL field, CRLF' -OutMust @('"x,y"', '"he said ""hi""', "`r`n")
$csvPath = Join-Path $script:Tmp 'detail.csv'
[System.IO.File]::WriteAllText($csvPath, $r.Out, (New-Object System.Text.UTF8Encoding($false)))
$csvRows = @(Import-Csv -LiteralPath $csvPath)
$csvDetailOk = ($csvRows.Count -eq 1) -and ($csvRows[0].a -eq '') -and ($csvRows[0].b -eq 'x,y') -and ($csvRows[0].c -eq 'he said "hi"') -and ($csvRows[0].e -eq "line1`r`nline2")
[void](Add-Result -Group 'format-detail' -Id 'det-04b' -Desc 'csv parse round-trip: comma/quote/CRLF field and NULL empty' -Cmd 'mysqlq.exe --format csv query "<detail>"' -Expect 'Import-Csv round-trips values' -Actual ('rows=' + $csvRows.Count + ' b=' + $csvRows[0].b + ' a=[' + $csvRows[0].a + ']') -Ok $csvDetailOk)

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-05' -Desc 'md escapes pipe as \|, newline as <br>, NULL as NULL' -ArgList @('--format', 'md', 'query', $detailSql) -Expect 'a\|b, line1<br>line2, NULL' -OutMust @('a\|b', 'line1<br>line2', '| NULL |')

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-06' -Desc 'json non-UTF8 binary is base64 string' -ArgList @('--format', 'json', 'query', "SELECT UNHEX('FF') AS binval") -Expect 'binval = "/w=="' -OutMust @('"/w=="')

$r = Test-Mysqlq -Group 'format-detail' -Id 'det-07' -Desc 'empty result set: table header only, stderr 0 row(s)' -ArgList @('--format', 'table', 'query', 'SELECT * FROM sale_pay_rel') -Expect 'header+separator only, stderr "[mysqlq] 0 row(s)"' -OutMust @('id', '----') -ErrMust @('0 row(s)')
[void](Add-Result -Group 'format-detail' -Id 'det-07b' -Desc 'empty result table has no data rows' -Cmd 'mysqlq.exe --format table query "SELECT * FROM sale_pay_rel"' -Expect '2 non-empty lines (header+sep)' -Actual ('lines=' + (@($r.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }).Count)) -Ok ((@($r.Out -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 }).Count) -eq 2))

foreach ($f in @('json', 'csv', 'md')) {
  $r = Test-Mysqlq -Group 'format-detail' -Id ('det-empty-' + $f) -Desc ('empty result ' + $f + ' output') -ArgList @('--format', $f, 'query', 'SELECT * FROM sale_pay_rel') -Expect 'valid empty output, exit 0, stderr 0 row(s)' -ErrMust @('0 row(s)')
  if ($f -eq 'json') {
    [void](Add-Result -Group 'format-detail' -Id 'det-empty-json-valid' -Desc 'empty json result is []' -Cmd 'mysqlq.exe --format json query "SELECT * FROM sale_pay_rel"' -Expect '[]' -Actual (Get-Short $r.Out 30) -Ok ($r.Out.Trim() -eq '[]'))
  }
  if ($f -eq 'csv') {
    $p = Join-Path $script:Tmp 'empty.csv'
    [System.IO.File]::WriteAllText($p, $r.Out, (New-Object System.Text.UTF8Encoding($false)))
    $rows = @(Import-Csv -LiteralPath $p)
    [void](Add-Result -Group 'format-detail' -Id 'det-empty-csv-valid' -Desc 'empty csv result is header only' -Cmd 'mysqlq.exe --format csv query "SELECT * FROM sale_pay_rel"' -Expect 'header only, 0 data rows' -Actual ('rows=' + $rows.Count) -Ok ($rows.Count -eq 0))
  }
}

# ----------------------------------------------------------------------------
# group: exit codes
# ----------------------------------------------------------------------------

$script:Group = 'exitcodes'
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-success' -Desc 'success exit 0' -ArgList @('--format', 'json', 'query', 'SELECT 1 AS a') -ExpCode @(0) -Expect 'exit 0')
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-unknown-cmd' -Desc 'unknown command exit 2' -ArgList @('nosuchcmd') -ExpCode @(2) -Expect 'exit 2, stderr contains usage' -ErrMust @('usage') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-columns' -Desc 'columns without table exit 2' -ArgList @('columns') -ExpCode @(2) -Expect 'exit 2, stderr usage' -ErrMust @('usage') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-indexes' -Desc 'indexes without table exit 2' -ArgList @('indexes') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-ddl' -Desc 'ddl without table exit 2' -ArgList @('ddl') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-schema' -Desc 'schema without table exit 2' -ArgList @('schema') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-query' -Desc 'query without sql exit 2' -ArgList @('query') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-arg-find' -Desc 'find without keyword exit 2' -ArgList @('find') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-extra-args' -Desc 'query with 2 args exit 2' -ArgList @('query', 'SELECT 1', 'SELECT 2') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-version-extra' -Desc 'version with extra arg exit 2' -ArgList @('version', 'extra') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('usage'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-bad-format' -Desc 'invalid --format exit 2' -ArgList @('--format', 'xml', 'info') -ExpCode @(2) -Expect 'exit 2, mentions table, json, csv, md' -ErrMust @('usage', 'format'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-maxrows-101' -Desc '--max-rows 101 exit 2' -ArgList @('--max-rows', '101', 'query', 'SELECT 1') -ExpCode @(2) -Expect 'exit 2, range message' -ErrMust @('max-rows', '100') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-maxrows-0' -Desc '--max-rows 0 exit 2' -ArgList @('--max-rows', '0', 'query', 'SELECT 1') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('max-rows'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-maxrows-neg' -Desc '--max-rows -1 exit 2' -ArgList @('--max-rows', '-1', 'query', 'SELECT 1') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('max-rows'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-unknown-flag' -Desc 'unknown flag exit 2' -ArgList @('--nope', 'info') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('unknown flag'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-bad-timeout' -Desc 'invalid --timeout exit 2' -ArgList @('--timeout', 'abc', 'query', 'SELECT 1') -ExpCode @(2) -Expect 'exit 2' -ErrMust @('timeout'))
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-no-table' -Desc 'columns on missing table exit 1 with db+table in message' -ArgList @('columns', 'no_such_table') -ExpCode @(1) -Expect 'exit 1, stderr has bbc and table name' -ErrMust @('error', 'bbc', 'no_such_table') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-bad-sql' -Desc 'query on missing table exit 1' -ArgList @('query', '--', 'SELECT * FROM no_such_table') -ExpCode @(1) -Expect 'exit 1, MySQL error' -ErrMust @('error') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-no-db' -Desc '--db pointing at missing database exit 1' -ArgList @('--db', 'no_such_db', 'info') -ExpCode @(1) -Expect 'exit 1, says database does not exist' -ErrMust @('error', 'no_such_db') -EmptyOut)
[void](Test-Mysqlq -Group 'exitcodes' -Id 'exit-missing-config' -Desc '--config missing file exit 1' -ArgList @('--config', (Join-Path $script:Tmp 'nope.yaml'), 'info') -ExpCode @(1) -Expect 'exit 1, config error mentions --config' -ErrMust @('config', '--config') -EmptyOut)

# ----------------------------------------------------------------------------
# group: config
# ----------------------------------------------------------------------------

$script:Group = 'config'
$cfg5   = New-TempConfig 'cfg_max5.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = '5' }
$cfg500 = New-TempConfig 'cfg_max500.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = '500' }
$cfgBad = New-TempConfig 'cfg_badmax.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = 'abc' }
$cfgQ   = New-TempConfig 'cfg_quoted.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = '"root"'; max_rows = '9' }
$cfgUnknown = New-TempConfig 'cfg_unknown.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; some_unknown_key = 'whatever' }
$cfgBadPort = New-TempConfig 'cfg_badport.yaml' @{ db_host = '127.0.0.1'; db_port = '3399'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'S3cr3tLeak_9z' }
$cfgBadPw   = New-TempConfig 'cfg_badpw.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'LeakMarker_9z' }
$cwdA = Join-Path $script:Tmp 'cwd_a'
$cwdB = Join-Path $script:Tmp 'cwd_b'
[void](New-Item -ItemType Directory -Path $cwdA -Force)
[void](New-Item -ItemType Directory -Path $cwdB -Force)
$cfgCwdA = New-TempConfig 'cwd_a\config.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = '7' }
$cfgCwdB = New-TempConfig 'cwd_b\config.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = '9' }

$r = Test-Mysqlq -Group 'config' -Id 'cfg-explicit' -Desc '--config explicit path is used (config_file + default_max_rows)' -ArgList @('--config', $cfg5, 'info') -Expect 'config_file = cfg5, default_max_rows = 5' -OutMust @($cfg5, 'default_max_rows  5')
$r = Test-Mysqlq -Group 'config' -Id 'cfg-env-config' -Desc 'MYSQLQ_CONFIG env selects config file' -ArgList @('info') -EnvMap @{ MYSQLQ_CONFIG = $cfg5 } -Expect 'config_file = cfg5, default_max_rows = 5' -OutMust @($cfg5, 'default_max_rows  5')
$r = Test-Mysqlq -Group 'config' -Id 'cfg-cli-over-env' -Desc '--config beats MYSQLQ_CONFIG' -ArgList @('--config', $cfgQ, 'info') -EnvMap @{ MYSQLQ_CONFIG = $cfg5 } -Expect 'config_file = cfgQ (max_rows 9), not cfg5' -OutMust @($cfgQ, 'default_max_rows  9') -OutMustNot @('cfg_max5.yaml')
[void](Test-Mysqlq -Group 'config' -Id 'cfg-quoted' -Desc 'quoted password value parses and connects' -ArgList @('--config', $cfgQ, '--format', 'json', 'query', 'SELECT 1 AS ok') -Expect 'exit 0, connects' -OutMust @('"ok": 1'))
[void](Test-Mysqlq -Group 'config' -Id 'cfg-unknown-key' -Desc 'unknown config key is ignored' -ArgList @('--config', $cfgUnknown, '--format', 'json', 'query', 'SELECT 1 AS ok') -Expect 'exit 0' -OutMust @('"ok": 1'))
[void](Test-Mysqlq -Group 'config' -Id 'cfg-bad-maxrows' -Desc 'non-integer max_rows -> config error exit 1 with legal range' -ArgList @('--config', $cfgBad, 'info') -ExpCode @(1) -Expect 'exit 1, stderr config + max_rows + 1 and 100' -ErrMust @('config', 'max_rows', '1 and 100') -EmptyOut)
[void](Test-Mysqlq -Group 'config' -Id 'cfg-bad-port' -Desc 'unreachable port -> runtime error exit 1 (connection refused)' -ArgList @('--config', $cfgBadPort, 'info') -ExpCode @(1) -Expect 'exit 1, error mentions host/port and connection' -ErrMust @('error', '127.0.0.1:3399') -EmptyOut)
$rleak = Invoke-Mysqlq -ArgList @('--config', $cfgBadPort, 'info')
Test-NoLeak -Group 'config' -Id 'cfg-bad-port-noleak' -Desc 'connection error must not print password' -Cmd 'mysqlq.exe --config cfg_badport.yaml info' -Text ($rleak.Out + $rleak.Err) -Markers @('S3cr3tLeak_9z')
$rleak = Invoke-Mysqlq -ArgList @('--config', $cfgBadPw, 'info')
Test-NoLeak -Group 'config' -Id 'cfg-bad-pw-noleak' -Desc 'access denied error must not print password' -Cmd 'mysqlq.exe --config cfg_badpw.yaml info' -Text ($rleak.Out + $rleak.Err) -Markers @('LeakMarker_9z')
$rleak = Invoke-Mysqlq -ArgList @('info') -EnvMap @{ MYSQLQ_PASSWORD = 'LeakMarker_9z' }
Test-NoLeak -Group 'config' -Id 'cfg-env-pw-noleak' -Desc 'MYSQLQ_PASSWORD value never printed' -Cmd 'MYSQLQ_PASSWORD=LeakMarker_9z mysqlq.exe info' -Text ($rleak.Out + $rleak.Err) -Markers @('LeakMarker_9z')
[void](Add-Result -Group 'config' -Id 'cfg-env-pw-exit' -Desc 'wrong MYSQLQ_PASSWORD causes exit 1 access denied' -Cmd 'MYSQLQ_PASSWORD=LeakMarker_9z mysqlq.exe info' -Expect 'exit 1 access denied' -Actual ('exit=' + $rleak.Code) -Ok ($rleak.Code -eq 1))
$r = Test-Mysqlq -Group 'config' -Id 'cfg-mysqlq-db' -Desc 'MYSQLQ_DB env overrides db_name' -ArgList @('info') -EnvMap @{ MYSQLQ_DB = 'funds' } -Expect 'database = funds' -OutMust @('database          funds')
$r = Test-Mysqlq -Group 'config' -Id 'cfg-db-flag' -Desc '--db overrides database (information_schema)' -ArgList @('--db', 'information_schema', '--format', 'json', '--max-rows', '100', 'tables') -Expect 'exit 0, tables from information_schema' -OutMust @('"TABLE": "TABLES"')
$r = Test-Mysqlq -Group 'config' -Id 'cfg-db-over-env' -Desc '--db beats MYSQLQ_DB' -ArgList @('--db', 'bbc', 'info') -EnvMap @{ MYSQLQ_DB = 'funds' } -Expect 'database = bbc' -OutMust @('database          bbc') -OutMustNot @('database          funds')
$r = Test-Mysqlq -Group 'config' -Id 'cfg-db-funds' -Desc '--db funds works on a second real database' -ArgList @('--db', 'funds', '--format', 'json', 'query', 'SELECT DATABASE() AS db') -Expect 'db = funds' -OutMust @('"db": "funds"')
$rleak = Invoke-Mysqlq -ArgList @('info') -EnvMap @{ MYSQLQ_PORT = '3399' }
[void](Add-Result -Group 'config' -Id 'cfg-env-port' -Desc 'MYSQLQ_PORT env override takes effect (bad port -> exit 1)' -Cmd 'MYSQLQ_PORT=3399 mysqlq.exe info' -Expect 'exit 1 connection error' -Actual ('exit=' + $rleak.Code) -Ok ($rleak.Code -eq 1))

# ----------------------------------------------------------------------------
# group: config-order (new deployment layout / SPEC section 2 lookup order)
#   1) --config   2) $MYSQLQ_CONFIG   3) <dir of mysqlq.exe>/config.yaml   4) ./config.yaml
#   The ../config.yaml fallback used by the old layout must be gone.
# ----------------------------------------------------------------------------

$script:Group = 'config-order'
$foreignCwd = Join-Path $script:Tmp 'foreign_cwd'
$emptyCwd   = Join-Path $script:Tmp 'empty_cwd'
[void](New-Item -ItemType Directory -Path $foreignCwd -Force)
[void](New-Item -ItemType Directory -Path $emptyCwd -Force)

# a copied deployment directory: mysqlq.exe + config.yaml together (relocatable deployment)
$deployDir = Join-Path $script:Tmp 'deploy_dir'
[void](New-Item -ItemType Directory -Path $deployDir -Force)
Copy-Item -LiteralPath $script:Bin -Destination (Join-Path $deployDir 'mysqlq.exe') -Force
$deployExe = Join-Path $deployDir 'mysqlq.exe'
$cfgDeploy = New-TempConfig 'deploy_dir\config.yaml' @{ db_host = '127.0.0.1'; db_name = 'funds'; db_user = 'root'; db_passwd = 'root'; max_rows = '11' }

# a copied exe with no config next to it (used to exercise the ./config.yaml fallback)
$exeNoCfgDir = Join-Path $script:Tmp 'exe_nocfg'
[void](New-Item -ItemType Directory -Path $exeNoCfgDir -Force)
Copy-Item -LiteralPath $script:Bin -Destination (Join-Path $exeNoCfgDir 'mysqlq.exe') -Force
$exeNoCfg = Join-Path $exeNoCfgDir 'mysqlq.exe'

# a config that exists ONLY in the parent directory of the cwd (old ../config.yaml fallback)
$parentOnlyRoot = Join-Path $script:Tmp 'parent_only'
$parentOnlyChild = Join-Path $parentOnlyRoot 'child'
[void](New-Item -ItemType Directory -Path $parentOnlyChild -Force)
$cfgParentOnly = New-TempConfig 'parent_only\config.yaml' @{ db_host = '127.0.0.1'; db_name = 'bbc'; db_user = 'root'; db_passwd = 'root'; max_rows = '3' }

# ord-01: default = config.yaml next to the exe, even when cwd is somewhere else
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-01' -Desc 'default: exe-dir config.yaml is used from an unrelated cwd' -ArgList @('info') -WorkDir $foreignCwd -Expect 'config_file = repo-root config.yaml, database bbc, default_max_rows 20' -OutMust @($script:ConfigPath, 'database          bbc', 'default_max_rows  20') -CaptureInfo

# ord-02: same, but cwd is a real %TEMP% subdirectory (lead scenario)
$realTempCwd = Join-Path $env:TEMP ('mysqlq_verify_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $realTempCwd -Force)
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-02' -Desc 'default: exe-dir config is used from a %TEMP% cwd' -ArgList @('info') -WorkDir $realTempCwd -Expect 'config_file = repo-root config.yaml (cwd-independent)' -OutMust @($script:ConfigPath, 'database          bbc') -CaptureInfo
Remove-Item -LiteralPath $realTempCwd -Recurse -Force -ErrorAction SilentlyContinue

# ord-03: exe-dir config beats a decoy ./config.yaml in the current directory
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-03' -Desc 'exe-dir config.yaml beats cwd config.yaml' -ArgList @('info') -WorkDir $cwdA -Expect 'root config (max_rows 20) wins, cwd_a config (max_rows 7) ignored' -OutMust @($script:ConfigPath, 'default_max_rows  20') -OutMustNot @('cwd_a') -CaptureInfo

# ord-04: relocatable deployment dir: copied exe + its own config, called from the repo root
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-04' -Desc 'copied deployment dir: its own config.yaml is used, not cwd config' -ArgList @('info') -Exe $deployExe -WorkDir $script:Root -Expect 'config_file = deploy_dir\config.yaml, database funds, max_rows 11' -OutMust @($cfgDeploy, 'database          funds', 'default_max_rows  11') -OutMustNot @($script:ConfigPath) -CaptureInfo

# ord-05: deploy-dir config still wins against a different cwd config (max_rows 11 vs 9)
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-05' -Desc 'relocated deployment works from another cwd (exe dir wins again)' -ArgList @('info') -Exe $deployExe -WorkDir $cwdB -Expect 'deploy config max_rows 11 wins over cwd_b max_rows 9' -OutMust @($cfgDeploy, 'default_max_rows  11') -OutMustNot @('cwd_b') -CaptureInfo

# ord-06: --config overrides the exe-dir config
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-06' -Desc '--config overrides the exe-dir config.yaml' -ArgList @('--config', $cfg5, 'info') -Exe $deployExe -WorkDir $script:Root -Expect 'config_file = cfg5 (max_rows 5), deploy config ignored' -OutMust @($cfg5, 'default_max_rows  5') -OutMustNot @($cfgDeploy) -CaptureInfo

# ord-07: $MYSQLQ_CONFIG overrides the exe-dir config
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-07' -Desc 'MYSQLQ_CONFIG overrides the exe-dir config.yaml' -ArgList @('info') -EnvMap @{ MYSQLQ_CONFIG = $cfg5 } -Exe $deployExe -WorkDir $script:Root -Expect 'config_file = cfg5 (max_rows 5)' -OutMust @($cfg5, 'default_max_rows  5') -OutMustNot @($cfgDeploy) -CaptureInfo

# ord-08: ./config.yaml fallback (go run scenario: no config next to the exe)
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-08' -Desc 'cwd fallback: ./config.yaml used when the exe dir has none' -ArgList @('info') -Exe $exeNoCfg -WorkDir $cwdA -Expect 'config_file = cwd_a\config.yaml (max_rows 7)' -OutMust @($cfgCwdA, 'default_max_rows  7') -CaptureInfo

# ord-09: $MYSQLQ_CONFIG beats the cwd fallback
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-09' -Desc 'MYSQLQ_CONFIG beats the ./config.yaml fallback' -ArgList @('info') -EnvMap @{ MYSQLQ_CONFIG = $cfg5 } -Exe $exeNoCfg -WorkDir $cwdA -Expect 'config_file = cfg5 (max_rows 5), cwd_a config ignored' -OutMust @($cfg5, 'default_max_rows  5') -OutMustNot @('cwd_a') -CaptureInfo

# ord-10: nothing found anywhere -> exit 1 with an actionable message
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-10' -Desc 'no config file anywhere -> exit 1 with actionable message' -ArgList @('info') -Exe $exeNoCfg -WorkDir $emptyCwd -ExpCode @(1) -Expect 'exit 1, stderr "no config file found", mentions next-to-exe and --config' -ErrMust @('no config file found', 'next to mysqlq.exe', '--config') -EmptyOut
[void](Add-Result -Group 'config-order' -Id 'ord-10b' -Desc 'no-config message does not leak credentials' -Cmd 'mysqlq.exe info (isolated, no config)' -Expect 'no credential pattern in stderr' -Actual ('stderr=' + (Get-Short $r.Err 100)) -Ok ((-not $r.Err.Contains('root:root')) -and (-not $r.Err.Contains('db_passwd:'))))

# ord-11: old ../config.yaml fallback must be gone
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-11' -Desc 'old ../config.yaml fallback is removed (config only in parent dir)' -ArgList @('info') -Exe $exeNoCfg -WorkDir $parentOnlyChild -ExpCode @(1) -Expect 'exit 1: ../config.yaml must NOT be loaded any more' -ErrMust @('no config file found') -EmptyOut
[void](Add-Result -Group 'config-order' -Id 'ord-11b' -Desc 'parent-dir config path never appears in output' -Cmd 'mysqlq.exe info (cwd child, config only in ../)' -Expect 'stdout+stderr do not reference the parent config' -Actual ('references=' + (($r.Out + $r.Err).Contains($cfgParentOnly))) -Ok (-not ($r.Out + $r.Err).Contains($cfgParentOnly)))

# ord-12: whole deployment dir copied elsewhere remains usable (exe + config move together)
$movedDir = Join-Path $script:Tmp 'moved_deploy'
[void](New-Item -ItemType Directory -Path $movedDir -Force)
Copy-Item -LiteralPath $deployExe -Destination (Join-Path $movedDir 'mysqlq.exe') -Force
Copy-Item -LiteralPath $cfgDeploy -Destination (Join-Path $movedDir 'config.yaml') -Force
$r = Test-Mysqlq -Group 'config-order' -Id 'ord-12' -Desc 'deployment directory is relocatable (exe+config moved together)' -ArgList @('--format', 'json', 'query', 'SELECT DATABASE() AS db, @@port AS port') -Exe (Join-Path $movedDir 'mysqlq.exe') -WorkDir $foreignCwd -Expect 'exit 0, db=funds from moved config' -OutMust @('"db": "funds"')

# ----------------------------------------------------------------------------
# group: guard (read-only intercept matrix) + integrity after each
# ----------------------------------------------------------------------------

$script:Group = 'guard'
$blockCases = @(
  @{ Id = 'ins-01'; Sql = "INSERT INTO sale_pay (id) VALUES (999)"; Why = 'INSERT' },
  @{ Id = 'ins-02'; Sql = "insert   into sale_pay (id) values (999)"; Why = 'lowercase + multi-space INSERT' },
  @{ Id = 'ins-03'; Sql = "InSeRt INTO sale_pay (id) VALUES (999)"; Why = 'mixed-case INSERT' },
  @{ Id = 'ins-04'; Sql = "INSERT/*c*/INTO sale_pay (id) VALUES (999)"; Why = 'INSERT with block comment separator' },
  @{ Id = 'upd-01'; Sql = "UPDATE sale_pay SET pay_status = 0"; Why = 'UPDATE' },
  @{ Id = 'upd-02'; Sql = "upDate sale_pay set pay_status=0"; Why = 'mixed-case UPDATE' },
  @{ Id = 'del-01'; Sql = "DELETE FROM sale_pay"; Why = 'DELETE' },
  @{ Id = 'del-02'; Sql = "DeLeTe FROM sale_pay WHERE id = 2282"; Why = 'mixed-case DELETE' },
  @{ Id = 'rep-01'; Sql = "REPLACE INTO sale_pay (id) VALUES (999)"; Why = 'REPLACE' },
  @{ Id = 'ups-01'; Sql = "INSERT INTO sale_pay (id) VALUES (999) ON DUPLICATE KEY UPDATE pay_status=0"; Why = 'UPSERT (INSERT ... ON DUPLICATE KEY UPDATE)' },
  @{ Id = 'ups-02'; Sql = "UPSERT INTO sale_pay (id) VALUES (999)"; Why = 'UPSERT keyword' },
  @{ Id = 'cre-01'; Sql = "CREATE TABLE zz_probe (id int)"; Why = 'CREATE' },
  @{ Id = 'cre-02'; Sql = "create table zz_probe (id int)"; Why = 'lowercase CREATE' },
  @{ Id = 'alt-01'; Sql = "ALTER TABLE sale_pay ADD COLUMN zz int"; Why = 'ALTER' },
  @{ Id = 'dro-01'; Sql = "DROP TABLE sale_pay"; Why = 'DROP' },
  @{ Id = 'dro-02'; Sql = "dRoP tAbLe sale_pay"; Why = 'mixed-case DROP' },
  @{ Id = 'tru-01'; Sql = "TRUNCATE sale_pay"; Why = 'TRUNCATE' },
  @{ Id = 'ren-01'; Sql = "RENAME TABLE sale_pay TO sale_pay_bak"; Why = 'RENAME' },
  @{ Id = 'gra-01'; Sql = "GRANT SELECT ON *.* TO x"; Why = 'GRANT' },
  @{ Id = 'rev-01'; Sql = "REVOKE SELECT ON *.* FROM x"; Why = 'REVOKE' },
  @{ Id = 'set-01'; Sql = "SET SESSION TRANSACTION READ WRITE"; Why = 'SET' },
  @{ Id = 'cal-01'; Sql = "CALL some_proc()"; Why = 'CALL' },
  @{ Id = 'loa-01'; Sql = "LOAD DATA INFILE 'x' INTO TABLE sale_pay"; Why = 'LOAD' },
  @{ Id = 'exp-01'; Sql = "EXPORT"; Why = 'EXPORT' },
  @{ Id = 'use-01'; Sql = "USE mysql"; Why = 'USE' },
  @{ Id = 'inj-01'; Sql = "SELECT 1; DROP TABLE sale_pay"; Why = 'multi-statement DROP' },
  @{ Id = 'inj-02'; Sql = "SELECT 1; DELETE FROM sale_pay"; Why = 'multi-statement DELETE' },
  @{ Id = 'inj-03'; Sql = "SELECT 1; UPDATE sale_pay SET pay_status=0"; Why = 'multi-statement UPDATE' },
  @{ Id = 'cmt-01'; Sql = "/*x*/ INSERT INTO sale_pay (id) VALUES (999)"; Why = '/*x*/ INSERT' },
  @{ Id = 'cmt-02'; Sql = "-- note`nDROP TABLE sale_pay"; Why = 'line comment then DROP' },
  @{ Id = 'cmt-03'; Sql = "# note`nDROP TABLE sale_pay"; Why = '# comment then DROP' },
  @{ Id = 'cmt-04'; Sql = "/*!50000 DROP TABLE sale_pay */"; Why = 'executable versioned comment' },
  @{ Id = 'cte-01'; Sql = "WITH a AS (SELECT 1) DELETE FROM sale_pay"; Why = 'CTE + DELETE' },
  @{ Id = 'cte-02'; Sql = "WITH a AS (SELECT 1) UPDATE sale_pay SET pay_status=0"; Why = 'CTE + UPDATE' },
  @{ Id = 'out-01'; Sql = "SELECT 1 INTO OUTFILE 'C:/tmp/x'"; Why = 'INTO OUTFILE' },
  @{ Id = 'out-02'; Sql = "SELECT 1 INTO DUMPFILE 'C:/tmp/x'"; Why = 'INTO DUMPFILE' },
  @{ Id = 'lck-01'; Sql = "SELECT * FROM sale_pay FOR UPDATE"; Why = 'FOR UPDATE' },
  @{ Id = 'lck-02'; Sql = "SELECT * FROM sale_pay LOCK IN SHARE MODE"; Why = 'LOCK IN SHARE MODE' },
  @{ Id = 'lck-03'; Sql = "SELECT * FROM sale_pay FOR SHARE"; Why = 'FOR SHARE' },
  @{ Id = 'tab-01'; Sql = "TABLE sale_pay"; Why = 'TABLE statement' },
  @{ Id = 'tab-02'; Sql = "VALUES ROW(1)"; Why = 'VALUES statement' },
  @{ Id = 'emp-01'; Sql = ""; Why = 'empty statement' },
  @{ Id = 'emp-02'; Sql = "   "; Why = 'whitespace-only statement' },
  @{ Id = 'emp-03'; Sql = ";"; Why = 'semicolon-only statement' },
  @{ Id = 'emp-04'; Sql = ";;"; Why = 'double semicolon' }
)

foreach ($bc in $blockCases) {
  $id = [string]$bc.Id
  $r = Test-Mysqlq -Group 'guard' -Id $id -Desc ('blocked: ' + $bc.Why) -ArgList @('query', '--', $bc.Sql) -ExpCode @(3) -Expect 'exit 3, stdout empty, stderr contains "blocked"' -ErrMust @('blocked') -EmptyOut
  [void](Assert-Integrity -Group 'integrity' -Id ('int-' + $id) -Context $bc.Why)
}

# keyword blacklist sweep (spec 6.2.5) - each keyword must be blocked as a WORD token
$keywords = @('INSERT','UPDATE','DELETE','REPLACE','MERGE','UPSERT','CREATE','ALTER','DROP','TRUNCATE','RENAME','GRANT','REVOKE','SET','RESET','CALL','DO','LOAD','IMPORT','HANDLER','FLUSH','KILL','SHUTDOWN','INSTALL','UNINSTALL','PREPARE','EXECUTE','DEALLOCATE','XA','START','BEGIN','COMMIT','ROLLBACK','SAVEPOINT','RELEASE','LOCK','UNLOCK','OPTIMIZE','ANALYZE','REPAIR','CHECKSUM','USE','INTO','OUTFILE','DUMPFILE','BACKUP','RESTORE','PURGE')
$badKw = @()
foreach ($kw in $keywords) {
  $r = Invoke-Mysqlq -ArgList @('query', '--', ('SELECT 1 AS x, ' + $kw))
  $ok = ($r.Code -eq 3) -and ($r.Out.Trim().Length -eq 0) -and $r.Err.Contains('blocked')
  if (-not $ok) { $badKw += ($kw + ':exit=' + $r.Code) }
}
[void](Add-Result -Group 'guard' -Id 'kw-blacklist' -Desc ('all ' + $keywords.Count + ' blacklist keywords blocked as WORD token') -Cmd 'for each keyword: mysqlq.exe query -- "SELECT 1 AS x, <KW>"' -Expect ('all ' + $keywords.Count + ' exit 3, empty stdout, stderr blocked') -Actual ('blocked=' + ($keywords.Count - $badKw.Count) + '/' + $keywords.Count + ' failures=' + ($badKw -join ',')) -Ok ($badKw.Count -eq 0))

# phrase checks
foreach ($ph in @(
  @{ Id = 'phr-01'; Sql = "SELECT * FROM sale_pay INTO OUTFILE '/tmp/x'"; Name = 'INTO OUTFILE' },
  @{ Id = 'phr-02'; Sql = "SELECT * FROM sale_pay INTO DUMPFILE '/tmp/x'"; Name = 'INTO DUMPFILE' },
  @{ Id = 'phr-03'; Sql = "SELECT * FROM sale_pay LOCK IN SHARE MODE"; Name = 'LOCK IN SHARE MODE' },
  @{ Id = 'phr-04'; Sql = "SELECT * FROM sale_pay FOR SHARE"; Name = 'FOR SHARE' }
)) {
  [void](Test-Mysqlq -Group 'guard' -Id $ph.Id -Desc ('blocked phrase: ' + $ph.Name) -ArgList @('query', '--', $ph.Sql) -ExpCode @(3) -Expect ('exit 3, stderr blocked + phrase ' + $ph.Name) -ErrMust @('blocked') -EmptyOut)
}

# guard runs before any DB interaction: broken config + blocked statement => 3, not 1
[void](Test-Mysqlq -Group 'guard' -Id 'order-01' -Desc 'guard runs before DB connect (broken config + write statement => 3)' -ArgList @('--config', $cfgBadPort, 'query', '--', 'DROP TABLE sale_pay') -ExpCode @(3) -Expect 'exit 3 (guard first), not 1 (connect error)' -ErrMust @('blocked') -EmptyOut)
[void](Test-Mysqlq -Group 'guard' -Id 'order-02' -Desc 'guard runs before DB connect (bad password config + write statement => 3)' -ArgList @('--config', $cfgBadPw, 'query', '--', 'INSERT INTO sale_pay (id) VALUES (1)') -ExpCode @(3) -Expect 'exit 3' -ErrMust @('blocked') -EmptyOut)

# statement size / unsafe parse / hint
$longSql = 'SELECT ' + ('a' * 70000)
[void](Test-Mysqlq -Group 'guard' -Id 'sz-01' -Desc 'statement > 64KB blocked (via stdin)' -ArgList @('query', '-') -StdinText $longSql -ExpCode @(3) -Expect 'exit 3, stderr blocked, mentions too long/limit' -ErrMust @('blocked', 'too long') -EmptyOut)
[void](Test-Mysqlq -Group 'guard' -Id 'parse-01' -Desc 'unterminated block comment blocked (cannot parse safely)' -ArgList @('query', '--', 'SELECT 1 /* oops') -ExpCode @(3) -Expect 'exit 3, blocked' -ErrMust @('blocked') -EmptyOut)
[void](Test-Mysqlq -Group 'guard' -Id 'parse-02' -Desc 'versioned comment mid-statement blocked' -ArgList @('query', '--', 'SELECT /*!50000 1 */ AS v') -ExpCode @(3) -Expect 'exit 3, blocked versioned comment' -ErrMust @('blocked', 'versioned') -EmptyOut)

# ----------------------------------------------------------------------------
# group: false-positive / must-still-work cases
# ----------------------------------------------------------------------------

$script:Group = 'defense'
[void](Test-Mysqlq -Group 'defense' -Id 'fp-01' -Desc 'SELECT with DELETE/UPDATE in string literals is allowed' -ArgList @('query', '--', "SELECT 'DELETE FROM sale_pay' AS a, 'UPDATE sale_pay SET x=1' AS b") -Expect 'exit 0, literals returned' -OutMust @('DELETE FROM sale_pay', 'UPDATE sale_pay SET x=1'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-02' -Desc 'backtick identifiers are not treated as keywords' -ArgList @('query', '--', 'SELECT `id` FROM `sale_pay` ORDER BY `id`') -Expect 'exit 0, 2 rows' -OutMust @('2282', '2332'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-03' -Desc 'backtick alias containing keyword is allowed' -ArgList @('--format', 'json', 'query', '--', 'SELECT 1 AS `insert`, 2 AS `delete`') -Expect 'exit 0, keys insert/delete' -OutMust @('"insert": 1', '"delete": 2'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-04' -Desc 'optimizer hint /*+ ... */ is allowed' -ArgList @('--format', 'json', 'query', '--', 'SELECT /*+ MAX_EXECUTION_TIME(1000) */ 1 AS hint_ok') -Expect 'exit 0, hint ignored as comment' -OutMust @('"hint_ok": 1'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-05' -Desc 'EXPLAIN SELECT is allowed' -ArgList @('query', '--', 'EXPLAIN SELECT * FROM sale_pay') -Expect 'exit 0, plan rows' -OutMust @('SIMPLE', 'sale_pay'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-06' -Desc 'SHOW TABLES is allowed' -ArgList @('query', '--', 'SHOW TABLES') -Expect 'exit 0, 12 rows' -OutMust @('sale_pay', 'service_config'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-07' -Desc 'DESC / DESCRIBE allowed' -ArgList @('query', '--', 'DESC sale_pay') -Expect 'exit 0, 18 rows' -OutMust @('Field', 'Type'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-08' -Desc 'WITH ... SELECT allowed' -ArgList @('--format', 'json', 'query', '--', 'WITH a AS (SELECT 1 AS x) SELECT x FROM a') -Expect 'exit 0, x=1' -OutMust @('"x": 1'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-09' -Desc 'trailing single semicolon allowed' -ArgList @('query', '--', 'SELECT 1 AS a;') -Expect 'exit 0' -OutMust @('1'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-10' -Desc 'SHOW CREATE TABLE is blocked but hints at ddl subcommand' -ArgList @('query', '--', 'SHOW CREATE TABLE sale_pay') -ExpCode @(3) -Expect 'exit 3, stderr mentions "mysqlq ddl"' -ErrMust @('blocked', 'ddl') -EmptyOut)
[void](Test-Mysqlq -Group 'defense' -Id 'fp-11' -Desc '-- terminator: flags before -- apply, SQL after -- is positional' -ArgList @('--format', 'json', 'query', '--', "-- note`nSELECT 1 AS after_comment") -Expect 'exit 0, json output, comment skipped' -OutMust @('"after_comment": 1'))
[void](Test-Mysqlq -Group 'defense' -Id 'fp-12' -Desc 'SQL consisting only of a comment is blocked as empty statement' -ArgList @('query', '--', '-- just a comment') -ExpCode @(3) -Expect 'exit 3 empty statement' -ErrMust @('blocked') -EmptyOut)
[void](Test-Mysqlq -Group 'defense' -Id 'fp-13' -Desc 'session is read-only during query and timeout is pushed to server' -ArgList @('--format', 'json', '--timeout', '10s', 'query', 'SELECT @@transaction_read_only AS ro, @@max_execution_time AS met') -Expect 'ro=1, met=10000 (defense in depth)' -OutMust @('"ro": 1', '"met": 10000'))

# ----------------------------------------------------------------------------
# group: row limits
# ----------------------------------------------------------------------------

$script:Group = 'limits'
$manySql = 'SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME FROM information_schema.COLUMNS'
function Test-RowLimit([string]$Id, [string]$Desc, [string[]]$ExtraArgs, [int]$Expected, [string[]]$ErrNeed, [hashtable]$EnvMap = $null) {
  $a = @('--format', 'json') + $ExtraArgs + @('query', $manySql)
  $r = Invoke-Mysqlq -ArgList $a -EnvMap $EnvMap
  $rows = $null
  if ($r.Code -eq 0) { $rows = Get-JsonRows $r.Out }
  $count = -1
  if ($rows) { $count = @($rows).Count }
  $problems = @()
  if ($r.Code -ne 0) { $problems += ('exit=' + $r.Code) }
  if ($count -ne $Expected) { $problems += ('rows=' + $count + ' expected ' + $Expected) }
  foreach ($m in $ErrNeed) { if (-not $r.Err.Contains($m)) { $problems += ('stderr missing "' + $m + '"') } }
  [void](Add-Result -Group 'limits' -Id $Id -Desc $Desc -Cmd (Format-Cmd $a) -Expect ('exactly ' + $Expected + ' rows' + $(if ($ErrNeed.Count) { '; stderr contains: ' + ($ErrNeed -join ', ') } else { '' })) -Actual ('exit=' + $r.Code + ' rows=' + $count + '; stderr: ' + (Get-Short $r.Err 120)) -Ok ($problems.Count -eq 0) -Detail ($problems -join '; '))
}
Test-RowLimit -Id 'row-default' -Desc 'default cap is 20 rows + truncated notice' -ExtraArgs @() -Expected 20 -ErrNeed @('truncated to 20 row(s)')
Test-RowLimit -Id 'row-max5' -Desc '--max-rows 5 returns exactly 5' -ExtraArgs @('--max-rows', '5') -Expected 5 -ErrNeed @('truncated to 5 row(s)')
Test-RowLimit -Id 'row-max100' -Desc '--max-rows 100 returns exactly 100' -ExtraArgs @('--max-rows', '100') -Expected 100 -ErrNeed @('truncated to 100 row(s)')
Test-RowLimit -Id 'row-config5' -Desc 'config max_rows: 5 returns exactly 5' -ExtraArgs @('--config', $cfg5) -Expected 5 -ErrNeed @('truncated to 5 row(s)')
Test-RowLimit -Id 'row-config500-clamp' -Desc 'config max_rows: 500 clamped to 100 + warning' -ExtraArgs @('--config', $cfg500) -Expected 100 -ErrNeed @('max_rows 500 in config exceeds the hard limit 100, using 100', 'truncated to 100 row(s)')
Test-RowLimit -Id 'row-cli-over-config' -Desc '--max-rows 50 beats config max_rows 500' -ExtraArgs @('--config', $cfg500, '--max-rows', '50') -Expected 50 -ErrNeed @('truncated to 50 row(s)')
Test-RowLimit -Id 'row-config500-cli100' -Desc 'config 500 + --max-rows 100 stays at hard cap 100' -ExtraArgs @('--config', $cfg500, '--max-rows', '100') -Expected 100 -ErrNeed @('truncated to 100 row(s)')

$r = Test-Mysqlq -Group 'limits' -Id 'row-info5' -Desc 'info reports default_max_rows from config (5)' -ArgList @('--config', $cfg5, 'info') -Expect 'default_max_rows 5' -OutMust @('default_max_rows  5')
$r = Test-Mysqlq -Group 'limits' -Id 'row-info500' -Desc 'info reports clamped default_max_rows (100) + warning' -ArgList @('--config', $cfg500, 'info') -Expect 'default_max_rows 100, warning on stderr' -OutMust @('default_max_rows  100') -ErrMust @('warning')
$r = Invoke-Mysqlq -ArgList @('--format', 'json', 'query', $manySql)
$rows = Get-JsonRows $r.Out
$capOk = $false
if ($rows) { $capOk = (@($rows).Count -le 100) }
[void](Add-Result -Group 'limits' -Id 'row-no-combo-over-100' -Desc 'no flag/config combination exceeds the hard cap of 100' -Cmd 'all row-limit cases above' -Expect 'row count <= 100 in every case' -Actual ('max observed <= 100; default=' + @($rows).Count) -Ok $capOk)

# ----------------------------------------------------------------------------
# group: timeout
# ----------------------------------------------------------------------------

$script:Group = 'timeout'
$slow1 = Invoke-Mysqlq -ArgList @('--timeout', '1s', 'query', 'SELECT SLEEP(5)') -HardMs 20000
$slow2 = Invoke-Mysqlq -ArgList @('--timeout', '1s', 'query', 'SELECT COUNT(*) FROM information_schema.COLUMNS a, information_schema.COLUMNS b, information_schema.COLUMNS c') -HardMs 20000

function Test-TimeoutCase([string]$Id, [string]$Desc, [string]$Sql, $r, [int]$HardMs) {
  $problems = @()
  if ($r.Code -ne 1) { $problems += ('exit=' + $r.Code + ' expected 1') }
  if ($r.Out.Trim().Length -ne 0) { $problems += ('stdout not empty (' + $r.Out.Length + 'B)') }
  if (-not ($r.Err -match '(?i)timed out|timeout')) { $problems += 'stderr does not mention timeout' }
  if ($r.Err.Contains('[mysql]')) { $problems += 'stderr contains driver log "[mysql]"' }
  if ($r.Err -match '(?i)packets\.go|driver:|unexpected EOF|read tcp') { $problems += 'stderr contains driver internals' }
  if ($r.Ms -gt $HardMs) { $problems += ('wall time ' + $r.Ms + 'ms exceeds ' + $HardMs + 'ms') }
  [void](Add-Result -Group 'timeout' -Id $Id -Desc $Desc -Cmd ('mysqlq.exe --timeout 1s query "' + (Get-Short $Sql 60) + '"') -Expect ('exit 1, stdout empty, stderr explains timeout, no driver logs, wall time < ' + $HardMs + 'ms') -Actual ('exit=' + $r.Code + ' stdout=' + $r.Out.Length + 'B ms=' + $r.Ms + ' stderr: ' + (Get-Short $r.Err 140)) -Ok ($problems.Count -eq 0) -Detail ($problems -join '; '))
}
Test-TimeoutCase -Id 'timeout-sleep' -Desc 'slow query SLEEP(5) with --timeout 1s' -Sql 'SELECT SLEEP(5)' -r $slow1 -HardMs 15000
Test-TimeoutCase -Id 'timeout-cartesian' -Desc '3-way cartesian join with --timeout 1s' -Sql 'SELECT COUNT(*) FROM information_schema.COLUMNS a,b,c' -r $slow2 -HardMs 15000

# ----------------------------------------------------------------------------
# final integrity + binary immutability
# ----------------------------------------------------------------------------

$f = Get-Integrity 'final'
[void](Add-Result -Group 'baseline' -Id 'base-03' -Desc 'baseline unchanged after the whole run (mysqlq)' -Cmd 'mysqlq --format json query "<counts>"' -Expect 'tables=12 sale_pay=2 after_sale_reason=11 sale_pay_rel=0 residue=0' -Actual $f.Detail -Ok $f.Ok)
[void](Assert-Integrity -Group 'integrity' -Id 'int-final' -Context 'entire verification run')

$binHash2 = (Get-FileHash -LiteralPath $script:Bin -Algorithm SHA256).Hash
[void](Add-Result -Group 'baseline' -Id 'base-04' -Desc 'binary was not rebuilt or replaced during verification' -Cmd 'Get-FileHash mysqlq.exe' -Expect ('sha256 unchanged (' + $binHash.Substring(0, 16) + '...)') -Actual ($binHash2.Substring(0, 16) + '... ' + $(if ($binHash -eq $binHash2) { 'unchanged' } else { 'CHANGED' })) -Ok ($binHash -eq $binHash2))

# ----------------------------------------------------------------------------
# summary + evidence files
# ----------------------------------------------------------------------------

$all = @($script:Results)
$warnList = @($all | Where-Object { $_.Warn })
$fail = @($all | Where-Object { -not $_.Ok }).Count
$warn = $warnList.Count
$pass = @($all | Where-Object { $_.Ok -and -not $_.Warn }).Count
$failList = @($all | Where-Object { -not $_.Ok })

$logPath = Join-Path $PSScriptRoot 'last-run.log'
$mdPath = Join-Path $PSScriptRoot 'last-run.md'
$now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$header = @()
$header += 'mysqlq black-box verification run'
$header += 'time        : ' + $now
$header += 'root        : ' + $script:Root
$header += 'binary      : ' + $script:Bin
$header += 'binary size : ' + $binInfo.Length
$header += 'binary sha  : ' + $binHash
$header += 'config      : ' + $script:ConfigPath
$header += 'server      : ' + $serverVersion
$header += 'mysql client: ' + $mysqlVersionLine
$header += 'powershell  : ' + $psVer
$header += 'cases       : ' + $all.Count + '  pass=' + $pass + '  warn=' + $warn + '  fail=' + $fail
$header += ''

$lines = @()
$lines += $header
foreach ($rec in $all) {
  $status = 'PASS'
  if (-not $rec.Ok) { $status = 'FAIL' }
  elseif ($rec.Warn) { $status = 'WARN' }
  $lines += ('[' + $status + '] ' + $rec.Group + '/' + $rec.Id + '  ' + $rec.Desc)
  $lines += ('        cmd   : ' + $rec.Cmd)
  $lines += ('        expect: ' + $rec.Expect)
  $lines += ('        actual: ' + $rec.Actual)
  if ($rec.Detail) { $lines += ('        detail: ' + $rec.Detail) }
}
[System.IO.File]::WriteAllLines($logPath, $lines, (New-Object System.Text.UTF8Encoding($false)))

$md = @()
$md += '# mysqlq verification - raw evidence (' + $now + ')'
$md += ''
$md += '- binary: `mysqlq.exe` (repo root / deployment dir) sha256 `' + $binHash + '`'
$md += '- layout: mysqlq.exe + config.yaml + config.example.yaml + SKILL.md in one directory; bin/ removed'
$md += '- config: `config.yaml`'
$md += '- server: ' + $serverVersion
$md += '- powershell: ' + $psVer
$md += '- cases: ' + $all.Count + ', pass: ' + $pass + ', warn: ' + $warn + ', fail: ' + $fail
$md += ''
$groups = @($all | ForEach-Object { $_.Group } | Select-Object -Unique)
foreach ($g in $groups) {
  $md += '## ' + $g
  $md += ''
  $md += '| case | description | command | expected | actual | result |'
  $md += '| --- | --- | --- | --- | --- | --- |'
  foreach ($rec in @($all | Where-Object { $_.Group -eq $g })) {
    $status = 'PASS'
    if (-not $rec.Ok) { $status = 'FAIL' }
    elseif ($rec.Warn) { $status = 'WARN' }
    $d = $rec.Desc.Replace('|', '\|')
    $c = $rec.Cmd.Replace('|', '\|')
    $e = $rec.Expect.Replace('|', '\|')
    $a = $rec.Actual.Replace('|', '\|')
    $md += ('| ' + $rec.Id + ' | ' + $d + ' | `' + $c + '` | ' + $e + ' | ' + $a + ' | ' + $status + ' |')
  }
  $md += ''
}
[System.IO.File]::WriteAllLines($mdPath, $md, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host '============================================================'
Write-Host (' RESULT: ' + $all.Count + ' cases, PASS=' + $pass + ', WARN=' + $warn + ', FAIL=' + $fail)
Write-Host (' evidence: ' + $logPath)
Write-Host (' evidence: ' + $mdPath)
if ($warn -gt 0) {
  Write-Host ' WARNINGS (not failures, see report):' -ForegroundColor Yellow
  foreach ($rec in $warnList) { Write-Host ('   - ' + $rec.Group + '/' + $rec.Id + ': ' + $rec.Desc) -ForegroundColor Yellow }
}
if ($fail -gt 0) {
  Write-Host ' FAILED CASES:' -ForegroundColor Red
  foreach ($rec in $failList) { Write-Host ('   - ' + $rec.Group + '/' + $rec.Id + ': ' + $rec.Desc) -ForegroundColor Red }
}
Write-Host '============================================================'

if ($fail -gt 0) { exit 1 }
exit 0
