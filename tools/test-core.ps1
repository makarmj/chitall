# Builds and tests ChitallCore with the Swift toolchain for Windows (or any swift on PATH).
# Usage: pwsh tools/test-core.ps1 [extra swift test arguments]
$ErrorActionPreference = 'Stop'

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    # A fresh winget install updates the user PATH/SDKROOT only for new sessions.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
    if ($sdk) { $env:SDKROOT = $sdk }
}

$package = Join-Path $PSScriptRoot '..\ChitallCore'
swift test --package-path $package @args
exit $LASTEXITCODE
