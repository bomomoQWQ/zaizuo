# Android debug/internal validation package only. Never runs sdkmanager --licenses,
# never changes system PATH or the existing shared Android SDK.
[CmdletBinding()]
param(
    [string]$WorkspaceRoot,
    [string]$FlutterRoot,
    [string]$JavaHome = 'C:\Program Files\Java\jdk-17',
    [string]$ExistingAndroidSdk = 'C:\Users\16706\AppData\Local\Android\Sdk',
    [ValidateSet('android-arm64', 'android-x64')][string]$Target = 'android-arm64',
    [ValidatePattern('^[0-9][0-9A-Za-z.+-]{0,63}$')][string]$Version = '0.1.0',
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
    $components = @('licenses','platform-tools','platforms\android-34','build-tools\34.0.0','cmdline-tools\latest')
    foreach ($component in $components) {
        $source = Join-Path $ExistingAndroidSdk $component
        $destination = Join-Path $android $component
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing preinstalled Android component: $component" }
        if (-not (Test-Path -LiteralPath $destination)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Recurse
        }
    }
}
foreach ($component in @('licenses\android-sdk-license','platforms\android-36\android.jar','build-tools\36.0.0\aapt2.exe','ndk\28.2.13676358\source.properties')) {
    if (-not (Test-Path -LiteralPath (Join-Path $android $component))) {
        throw 'Isolated Android SDK incomplete. Need platform/build-tools 36 and NDK 28.2.13676358. PrepareSdk only copies preinstalled SDK34; explicitly prepare the new components under this isolated SDK after license review. This script does not download or accept licenses.'
    }
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
        Flutter -Arguments @('pub','get')
        Flutter -Arguments @('analyze')
        if (-not $SkipTests) { Flutter -Arguments @('test','--reporter','expanded') }
        Flutter -Arguments @('build','apk','--debug','--target-platform',$Target,'--no-pub')
        $apk = Join-Path $PWD 'build\app\outputs\flutter-apk\app-debug.apk'
        if (-not (Test-Path -LiteralPath $apk)) { throw 'Expected debug APK not produced.' }
        $out = Join-Path $root 'dist\packages'
        New-Item -ItemType Directory -Force -Path $out | Out-Null
        $destination = Join-Path $out "zaizuo-mobile-probe-$Version-$Target-debug.apk"
        if (Test-Path -LiteralPath $destination) { throw 'Versioned APK already exists; refusing overwrite. Use a new Version.' }
        Copy-Item -LiteralPath $apk -Destination $destination
        $sha = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -LiteralPath "$destination.sha256" -Value "$sha  $([IO.Path]::GetFileName($destination))" -Encoding ascii
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
