param([string]$DartExe,[string]$GoExe,[switch]$SkipGitIntegration)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
if(-not $DartExe){$DartExe=Join-Path $root '.local\dart-sdk\bin\dart.exe'}
if(-not $GoExe){$GoExe=Join-Path $root '.local\go\bin\go.exe'}
$env:PUB_CACHE=Join-Path $root '.local\pub-cache'
$env:TEMP=Join-Path $root '.local\temp';$env:TMP=$env:TEMP
$env:APPDATA=Join-Path $root '.local\dart-user';$env:LOCALAPPDATA=$env:APPDATA
$env:DART_SUPPRESS_ANALYTICS='true'
New-Item -ItemType Directory -Force -Path $env:TEMP,$env:APPDATA | Out-Null
function Invoke-Checked([string]$exe,[string[]]$arguments){
  & $exe @arguments
  if($LASTEXITCODE -ne 0){throw "Check failed: $exe $($arguments -join ' ') ($LASTEXITCODE)"}
}
foreach($package in @('core','domain','relay_dart','onebot','runtime')){
  Push-Location (Join-Path $root "packages\$package")
  try{
    Invoke-Checked $DartExe @('pub','get')
    $targets=@('lib','test');if(Test-Path 'bin'){$targets+='bin'};if(Test-Path 'example'){$targets+='example'}
    Invoke-Checked $DartExe (@('format','--output=none','--set-exit-if-changed')+$targets)
    Invoke-Checked $DartExe @('analyze')
    if($SkipGitIntegration -and $package -eq 'core'){
      Invoke-Checked $DartExe @('test','test/security_test.dart','test/attachments_test.dart','test/image_codec_test.dart','test/webp_encoder_test.dart','-r','expanded')
    }else{Invoke-Checked $DartExe @('test','-r','expanded')}
  }finally{Pop-Location}
}
Push-Location (Join-Path $root 'relay-go')
try{
  Invoke-Checked $GoExe @('test','./...','-count=1','-timeout=90s')
  Invoke-Checked $GoExe @('vet','./...')
  Invoke-Checked $GoExe @('build','./...')
}finally{Pop-Location}
Write-Output 'All selected checks passed.'
