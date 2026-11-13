[CmdletBinding()]
param(
    [string]$DartExe,
    [string]$OutDir,
    [string]$Version = '0.1.0-dev',
    [ValidateSet('Snapshot','Exe')][string]$Mode = 'Snapshot',
    [switch]$SkipPubGet,
    [switch]$SkipSmoke
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not $DartExe) { $DartExe = Join-Path $root '.local\dart-sdk\bin\dart.exe' }
$DartExe = (Get-Item -LiteralPath $DartExe -ErrorAction Stop).FullName
if (-not $OutDir) { $OutDir = Join-Path $root 'dist\packages' }
$OutDir = [IO.Path]::GetFullPath($OutDir)
if ($Version -notmatch '^[0-9][0-9A-Za-z.+-]*$') { throw 'Version只能含安全ASCII版本字符。' }
if ($env:OS -ne 'Windows_NT') { throw '请在Windows本机运行；本脚本不伪装交叉编译。' }
$stamp = [Guid]::NewGuid().ToString('N')
$name = "zaizuo-cli-$Version-windows-x64-$($Mode.ToLowerInvariant())"
$buildRoot = Join-Path $root ".local\package-build\$stamp"
$stage = Join-Path $buildRoot $name
$work = Join-Path $buildRoot 'work'
$payload = Join-Path $stage 'bin'
$null = New-Item -ItemType Directory -Path $stage,$work,$payload,$OutDir -Force
$archive = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $archive) { throw "目标已存在，拒绝覆盖：$archive；使用新版本或明确自行处理旧包。" }
$env:PUB_CACHE = Join-Path $root '.local\pub-cache'
$env:TEMP = Join-Path $root '.local\temp'; $env:TMP = $env:TEMP
$env:APPDATA = Join-Path $root '.local\dart-user'; $env:LOCALAPPDATA = $env:APPDATA
$env:DART_SUPPRESS_ANALYTICS = 'true'
$null = New-Item -ItemType Directory -Path $env:PUB_CACHE,$env:TEMP,$env:APPDATA -Force
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "构建步骤失败（exit=$LASTEXITCODE）。不自动切换路径/权限，请保留诊断输出。" }
}
$runtime = Join-Path $root 'packages\runtime'
$sdk = Split-Path (Split-Path $DartExe -Parent) -Parent
$dartVersion = (& $DartExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $dartVersion -notmatch 'windows_x64') { throw '当前打包只验证Windows x64 SDK。' }
Push-Location $runtime
try {
    if (-not $SkipPubGet) { Invoke-Checked $DartExe @('pub','get','--enforce-lockfile') }
    if (-not (Test-Path '.dart_tool\package_config.json')) { throw '缺少package_config；先pub get。' }
    if ($Mode -eq 'Exe') {
        # 此标准路径若遇Unicode gen_snapshot失败，立即停止；不暗中转成snapshot宣称EXE。
        Invoke-Checked $DartExe @('compile','exe','bin/zaizuo.dart','-o',(Join-Path $payload 'zaizuo.exe'))
    } else {
        # Windows Dart3.14 gen_snapshot的绝对中文argv路径故障：在同一目录用相对ASCII参数。
        # 不复制源码、修改ACL、移动工作区或改SDK。选此Mode是显式的AOT+runtime产品形态。
        $aotRuntime = Join-Path $sdk 'bin\dartaotruntime.exe'
        $genKernel = Join-Path $sdk 'bin\snapshots\gen_kernel_aot.dart.snapshot'
        $platform = Join-Path $sdk 'lib\_internal\vm_platform_product.dill'
        $generator = Join-Path $sdk 'bin\utils\gen_snapshot.exe'
        foreach ($file in @($aotRuntime,$genKernel,$platform,$generator)) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "SDK缺少构建工具：$file" }
        }
        Push-Location $work
        try {
            Invoke-Checked $aotRuntime @($genKernel,'--platform',$platform,'--packages',(Join-Path $runtime '.dart_tool\package_config.json'),'--aot','--no-embed-sources','--target-os','windows','-Ddart.vm.product=true','--output','program.dill',(Join-Path $runtime 'bin\zaizuo.dart'))
            Invoke-Checked $generator @('--snapshot_kind=app-aot-elf','--elf=zaizuo.aot','program.dill')
            Copy-Item -LiteralPath (Join-Path $work 'zaizuo.aot') -Destination (Join-Path $payload 'zaizuo.aot')
            Copy-Item -LiteralPath $aotRuntime -Destination (Join-Path $payload 'dartaotruntime.exe')
        } finally { Pop-Location }
    }
} finally { Pop-Location }
$licenses = Join-Path $stage 'licenses'
$null = New-Item -ItemType Directory -Path $licenses
Invoke-Checked $DartExe @((Join-Path $PSScriptRoot 'collect_licenses.dart'),(Join-Path $runtime '.dart_tool\package_config.json'),(Join-Path $runtime 'pubspec.lock'),$licenses)
Copy-Item -LiteralPath (Join-Path $sdk 'LICENSE') -Destination (Join-Path $licenses 'Dart-SDK-LICENSE.txt')
foreach ($notice in @('THIRD_PARTY_NOTICES','third_party/NOTICES','NOTICES')) {
    $source = Join-Path $sdk $notice
    if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $licenses ('Dart-' + ($notice -replace '[/\\]','-')) ) }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'runtime.env.example') -Destination (Join-Path $stage 'runtime.env.example')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'PORTABLE-README.md') -Destination (Join-Path $stage 'README.md')
$cmd = if ($Mode -eq 'Snapshot') { '"%~dp0bin\dartaotruntime.exe" "%~dp0bin\zaizuo.aot" %*' } else { '"%~dp0bin\zaizuo.exe" %*' }
$launcher = "@echo off`r`nsetlocal`r`nif defined ZAIZUO_GIT_BIN_DIR set `"PATH=%ZAIZUO_GIT_BIN_DIR%;%PATH%`"`r`nif defined ZAIZUO_CWEBP_BIN_DIR set `"PATH=%ZAIZUO_CWEBP_BIN_DIR%;%PATH%`"`r`n$cmd`r`nexit /b %errorlevel%`r`n"
[IO.File]::WriteAllText((Join-Path $stage 'zaizuo.cmd'),$launcher,[Text.Encoding]::ASCII)
$metadata = [ordered]@{project='zaizuo';version=$Version;platform='windows-x64';mode=$Mode.ToLowerInvariant();dart=$dartVersion;created_utc=[DateTime]::UtcNow.ToString('o');smoke_tested=(-not $SkipSmoke);git_bundled=$false;cwebp_bundled=$false;project_license='undecided-internal-testing-only'}
[IO.File]::WriteAllText((Join-Path $stage 'BUILD.json'),($metadata | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if (-not $SkipSmoke) {
    Push-Location $stage
    try {
        if ($Mode -eq 'Snapshot') { Invoke-Checked (Join-Path $payload 'dartaotruntime.exe') @('bin/zaizuo.aot','--help') }
        else { Invoke-Checked (Join-Path $payload 'zaizuo.exe') @('--help') }
    } finally { Pop-Location }
}
# 只遍历显式构建的新stage；不扫描或拷贝仓库、profile、Git远端或环境secret。
$hashes = Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($stage.Length + 1).Replace('\','/')
    "{0}  {1}" -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$relative
}
[IO.File]::WriteAllLines((Join-Path $stage 'SHA256SUMS'),$hashes,[Text.Encoding]::ASCII)
Compress-Archive -LiteralPath $stage -DestinationPath $archive -CompressionLevel Optimal
$archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText("$archive.sha256","$archiveHash  $([IO.Path]::GetFileName($archive))`n",[Text.Encoding]::ASCII)
Write-Output "已创建：$archive"
Write-Output "SHA256：$archiveHash"
Write-Output "构建中间文件保留于：$buildRoot（脚本不自动删除目录）。"
