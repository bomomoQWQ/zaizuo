# 使用现有便携 SDK；不安装、不修改系统 PATH、不启动公网服务。
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$go = Join-Path $root '.local/go/bin/go.exe'
$dart = Join-Path $root '.local/dart-sdk/bin/dart.exe'
if (-not (Test-Path -LiteralPath $go -PathType Leaf)) { throw 'Portable Go SDK is not available.' }
if (-not (Test-Path -LiteralPath $dart -PathType Leaf)) { throw 'Portable Dart SDK is not available.' }

$environment = @{
    PUB_CACHE = (Join-Path $root '.local/pub-cache')
    TEMP = (Join-Path $root '.local/temp')
    TMP = (Join-Path $root '.local/temp')
    APPDATA = (Join-Path $root '.local/dart-user')
    LOCALAPPDATA = (Join-Path $root '.local/dart-user')
    DART_SUPPRESS_ANALYTICS = 'true'
}
$previous = @{}
foreach ($name in $environment.Keys) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
}
try {
    foreach ($name in @('PUB_CACHE', 'TEMP', 'APPDATA')) {
        New-Item -ItemType Directory -Force -Path $environment[$name] | Out-Null
    }
    $binaryDirectory = Join-Path $root '.local/bin'
    New-Item -ItemType Directory -Force -Path $binaryDirectory | Out-Null
    Push-Location (Join-Path $root 'relay-go')
    try {
        & $go build -mod=readonly -o (Join-Path $binaryDirectory 'relay-interop.exe') ./cmd/relay
        if ($LASTEXITCODE -ne 0) { throw 'Go relay build failed.' }
    } finally { Pop-Location }

    Push-Location $PSScriptRoot
    try {
        & $dart pub get
        if ($LASTEXITCODE -ne 0) { throw 'Dart dependencies could not be resolved.' }
        & $dart analyze
        if ($LASTEXITCODE -ne 0) { throw 'Dart interop analysis failed.' }
        # All children use inherited stdio and are bounded/joined by run.dart.
        & $dart run bin/run.dart
        if ($LASTEXITCODE -ne 0) { throw 'Relay endpoint interoperability failed.' }
    } finally { Pop-Location }
} finally {
    foreach ($name in $previous.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
    }
}
