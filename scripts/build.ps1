# Build mysqlq into the repo root (next to config.yaml / SKILL.md).
# Layout: mysqlq.exe + config.yaml + SKILL.md live in the same directory, so the
# tool always finds its config next to the executable.
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build.ps1
param(
    [string]$Output = 'mysqlq.exe'
)

. (Join-Path $PSScriptRoot 'env.ps1')

$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $outDir = Split-Path -Parent (Join-Path $root $Output)
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    go build -trimpath -buildvcs=false -o $Output .
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}