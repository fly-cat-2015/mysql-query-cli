# Local CI for mysqlq: gofmt check, go vet, go test.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\ci.ps1
# Keep ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without BOM.
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'env.ps1')

Push-Location (Split-Path -Parent $PSScriptRoot)
try {
    Write-Host '=== gofmt -l . ==='
    $unformatted = gofmt -l .
    if ($unformatted) { $unformatted; $fmtFailed = $true } else { Write-Host 'clean' }

    Write-Host '=== go vet ./... ==='
    go vet ./...
    $vetExit = $LASTEXITCODE

    Write-Host '=== go test ./... ==='
    go test ./...
    $testExit = $LASTEXITCODE

    Write-Host ''
    Write-Host ("gofmt_failed={0} vet_exit={1} test_exit={2}" -f [bool]$fmtFailed, $vetExit, $testExit)
    if ($fmtFailed -or $vetExit -ne 0 -or $testExit -ne 0) { exit 1 }
    exit 0
}
finally {
    Pop-Location
}