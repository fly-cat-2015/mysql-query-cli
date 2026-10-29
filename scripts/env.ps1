# Shared build environment for this workspace.
# Dot-source it before any `go` command:  . .\scripts\env.ps1
# The module/build caches live inside the workspace so the sandbox can write
# them, and the checksum database is disabled because its cache path is not
# writable here. go.sum still records every module hash.

$wsRoot = Split-Path -Parent $PSScriptRoot
$env:GOCACHE = Join-Path $wsRoot '.cache\gocache'
$env:GOMODCACHE = Join-Path $wsRoot '.cache\gomodcache'
$env:GOSUMDB = 'off'
$env:GOPROXY = 'https://goproxy.cn,direct'
$env:CGO_ENABLED = '0'
$env:GOFLAGS = ''