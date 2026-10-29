# Build the mysqlq binary into .\bin\mysqlq.exe
#   pwsh -NoProfile -File .\scripts\build.ps1
param(
    [string]$Output = 'bin/mysqlq.exe'
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