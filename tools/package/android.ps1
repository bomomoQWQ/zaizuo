# Android debug/internal validation package only. Never runs sdkmanager --licenses,
# never changes system PATH or the existing shared Android SDK.
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$FlutterRoot,
    [string]$JavaHome = 'C:\Program Files\Java\jdk-17',
    [string]$ExistingAndroidSdk = 'C:\Users\16706\AppData\Local\Android\Sdk',
    [ValidateSet('android-arm64', 'android-x64')][string]$Target = 'android-arm64',
    [ValidatePattern('^[0-9][0-9A-Za-z.+-]{0,63}$')][string]$Version = '0.1.0-media-test3',
    [switch]$PrepareSdk,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$root = if ($WorkspaceRoot) { $WorkspaceRoot.TrimEnd('\') } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if (-not (Test-Path -LiteralPath (Join-Path $root 'apps\mobile_probe\pubspec.yaml'))) { throw 'WorkspaceRoot must be the existing zaizuo checkout (an explicit ASCII junction is supported).' }
if (-not $FlutterRoot) { $FlutterRoot = Join-Path $root '.local\flutter' }
$FlutterRoot = (Resolve-Path -LiteralPath $FlutterRoot).Path
$flutter = Join-Path $FlutterRoot 'bin\flutter.bat'
$java = Join-Path $JavaHome 'bin\java.exe'
$android = Join-Path $root '.local\android-sdk'
if (-not (Test-Path -LiteralPath $flutter) -or -not (Test-Path -LiteralPath $java)) {
    throw 'Need the verified portable Flutter checkout and JDK17; do not use the default Java9.'
}
if ($PrepareSdk) {
    $components = @('licenses','platform-tools','platforms\android-36','build-tools\36.0.0','cmdline-tools\latest','ndk\28.2.13676358')
    foreach ($component in $components) {
        $source = Join-Path $ExistingAndroidSdk $component
        $destination = Join-Path $android $component
        if (Test-Path -LiteralPath $destination) { continue }
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing preinstalled Android component: $component. PrepareSdk never downloads components or accepts licenses." }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Recurse
    }
}
foreach ($component in @('licenses\android-sdk-license','platforms\android-36\android.jar','build-tools\36.0.0\aapt2.exe','build-tools\36.0.0\apksigner.bat','ndk\28.2.13676358\source.properties')) {
    if (-not (Test-Path -LiteralPath (Join-Path $android $component))) {
        throw 'Isolated Android SDK incomplete. Need platform/build-tools 36 and NDK 28.2.13676358. PrepareSdk only copies already installed components; explicitly prepare missing versions under this isolated SDK after license review. This script does not download or accept licenses.'
    }
}
$app = Join-Path $root 'apps\mobile_probe'
$pubspec = Get-Content -LiteralPath (Join-Path $app 'pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version: 0\.1\.0\+2\s*$') { throw 'Expected mobile probe version 0.1.0+2 for the media-test3 APK.' }
$licensePairs = @(
    @{ Source = 'LICENSE'; Asset = 'assets/licenses/AGPL-3.0-only.txt' },
    @{ Source = 'NOTICE'; Asset = 'assets/licenses/NOTICE.txt' }
)
foreach ($pair in $licensePairs) {
    $source = Join-Path $root $pair.Source
    $asset = Join-Path $app $pair.Asset
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $asset -PathType Leaf)) {
        throw "Missing project license/notice: $($pair.Asset). Copy the root original verbatim before building."
    }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash) {
        throw "Stale project license asset: $($pair.Asset). Must match the root original byte-for-byte."
    }
    if ($pubspec -notmatch ('(?m)^\s+-\s+' + [regex]::Escape($pair.Asset) + '\s*$')) { throw "License asset not declared in pubspec: $($pair.Asset)" }
}
$sourceUrl = "https://github.com/bomomoQWQ/zaizuo/tree/v$Version"
if (-not (Get-Content -LiteralPath (Join-Path $app 'lib\project_licenses.dart') -Raw).Contains($sourceUrl)) {
    throw 'The in-app corresponding-source URL must match the package Version/tag. Update the release metadata and tests together.'
}
$out = Join-Path $root 'dist\packages'
$destination = Join-Path $out "zaizuo-mobile-probe-$Version-$Target-debug.apk"
foreach ($candidate in @($destination, "$destination.sha256")) {
    if (Test-Path -LiteralPath $candidate) { throw 'Versioned APK/checksum already exists; refusing overwrite. Use a new Version and matching source tag.' }
}
$stamp = Join-Path $FlutterRoot 'bin\cache\engine-dart-sdk.stamp'
$engine = Join-Path $FlutterRoot 'bin\internal\engine.version'
$dartLink = Join-Path $FlutterRoot 'bin\cache\dart-sdk'
if ((Get-Item -LiteralPath $dartLink).LinkType -eq 'Junction') {
    if ((Get-Content -LiteralPath $stamp -Raw).Trim() -ne (Get-Content -LiteralPath $engine -Raw).Trim()) {
        throw 'Flutter engine/Dart junction stamp mismatch. Stop: never let a Flutter update recursively replace the shared Dart target.'
    }
}
$parentDart = Join-Path $root '.local\dart-sdk\bin\dart.exe'
$before = if (Test-Path -LiteralPath $parentDart) { (Get-FileHash -LiteralPath $parentDart -Algorithm SHA256).Hash } else { $null }
$names = @('JAVA_HOME','ANDROID_HOME','ANDROID_SDK_ROOT','ANDROID_USER_HOME','GRADLE_USER_HOME','PUB_CACHE','TEMP','TMP','APPDATA','LOCALAPPDATA','USERPROFILE','HOME','CI','DART_SUPPRESS_ANALYTICS','FLUTTER_SUPPRESS_ANALYTICS','PATH','GRADLE_OPTS')
$prior = @{}
foreach ($name in $names) { $prior[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
function Flutter([string[]]$Arguments) {
    & $flutter @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter command failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}
try {
    $env:JAVA_HOME = $JavaHome
    $env:ANDROID_HOME = $android
    $env:ANDROID_SDK_ROOT = $android
    $env:ANDROID_USER_HOME = Join-Path $root '.local\android-user'
    $env:GRADLE_USER_HOME = Join-Path $root '.local\gradle'
    $env:PUB_CACHE = Join-Path $root '.local\pub-cache'
    $env:TEMP = Join-Path $root '.local\temp'
    $env:TMP = $env:TEMP
    $env:APPDATA = Join-Path $root '.local\flutter-user'
    $env:LOCALAPPDATA = $env:APPDATA
    $env:USERPROFILE = $env:APPDATA
    $env:HOME = $env:USERPROFILE
    $env:CI = 'true'
    $env:DART_SUPPRESS_ANALYTICS = 'true'
    $env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
    $env:GRADLE_OPTS = "-Duser.home=$env:USERPROFILE -Djava.io.tmpdir=$env:TEMP"
    $env:PATH = "$JavaHome\bin;$env:PATH"
    New-Item -ItemType Directory -Force -Path $env:GRADLE_USER_HOME,$env:TEMP,$env:APPDATA | Out-Null
    Push-Location (Join-Path $root 'apps\mobile_probe')
    try {
        Flutter -Arguments @('--version')
        Flutter -Arguments @('pub','get','--offline','--enforce-lockfile')
        Flutter -Arguments @('analyze','--no-pub')
        if (-not $SkipTests) { Flutter -Arguments @('test','--no-pub','--reporter','expanded') }
        Flutter -Arguments @('build','apk','--debug','--target-platform',$Target,'--no-pub')
        $apk = Join-Path $PWD 'build\app\outputs\flutter-apk\app-debug.apk'
        if (-not (Test-Path -LiteralPath $apk)) { throw 'Expected debug APK not produced.' }
        # Validate the built ZIP as well as the source assets: never ship stale
        # LICENSE/NOTICE or discard Flutter's upstream third-party notices.
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($apk)
        try {
            foreach ($pair in $licensePairs) {
                $entry = $zip.GetEntry("assets/flutter_assets/$($pair.Asset)")
                if (-not $entry) { throw "Project license absent from built APK: $($pair.Asset)" }
                $stream = $entry.Open()
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $hash = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '') }
                finally { $stream.Dispose(); $hasher.Dispose() }
                if ($hash -ne (Get-FileHash -LiteralPath (Join-Path $root $pair.Source) -Algorithm SHA256).Hash) {
                    throw "Built APK license differs from root original: $($pair.Asset)"
                }
            }
            $thirdParty = $zip.GetEntry('assets/flutter_assets/NOTICES.Z')
            if (-not $thirdParty -or $thirdParty.Length -le 0) { throw 'Flutter third-party NOTICES.Z absent from built APK.' }
        } finally { $zip.Dispose() }
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        foreach ($candidate in @($destination, "$destination.sha256")) {
            if (Test-Path -LiteralPath $candidate) { throw 'Versioned APK/checksum already exists; refusing overwrite.' }
        }
        [IO.File]::Copy($apk, $destination, $false)
        $sha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $checksum = [IO.File]::Open("$destination.sha256", [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::ASCII.GetBytes("$sha  $([IO.Path]::GetFileName($destination))`n")
            $checksum.Write($bytes, 0, $bytes.Length)
        } finally { $checksum.Dispose() }
        Write-Output "DEBUG_INTERNAL_APK=$destination"
        Write-Output "SHA256=$sha"
        Write-Output 'Not production signing; install/run on a device still requires separate verification.'
    } finally { Pop-Location }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $prior[$name], 'Process') }
    if ($before -and (Get-FileHash -LiteralPath $parentDart -Algorithm SHA256).Hash -ne $before) {
        throw 'Parent Dart executable changed; investigate before continuing.'
    }
}
