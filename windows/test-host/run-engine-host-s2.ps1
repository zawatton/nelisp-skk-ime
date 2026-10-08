[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateSet('Contracts','Soak','EndToEnd')][string]$Stage='EndToEnd',
      [string]$LargeDictionary='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$run=Join-Path $root ($BuildDir+'/s2-gates-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$checks=0
function Gate([string]$name,[string]$exe,[string[]]$arguments) {
  $log=Join-Path $run ("$checks-$name.log")
  Write-Output ("cmd: $exe "+($arguments -join ' '))
  & $exe @arguments *> $log
  $code=$LASTEXITCODE
  Get-Content -LiteralPath $log -Tail 8
  if($code -ne 0){throw "FAIL $name exit=$code log=$log"}
  $script:checks++
}
function ScriptGate([string]$name,[string[]]$arguments) {
  Gate $name 'pwsh' (@('-NoProfile','-File',(Join-Path $PSScriptRoot ($name+'.ps1')))+$arguments)
}
$common=@('-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec','45')
if($Stage -eq 'Soak') {
  ScriptGate 'test-private-pipe-soak' $common
} else {
  Gate 'integrity' 'python' @((Join-Path $PSScriptRoot 'verify-host-contracts.py'))
  ScriptGate 'test-host-contracts' $common
  ScriptGate 'test-host-contracts' ($common+@('-Engine','lattice','-Fixture','docs/contracts/native-legacy-v1.json'))
  if($Stage -eq 'EndToEnd') {
    if(-not $LargeDictionary -or -not (Test-Path -LiteralPath $LargeDictionary)){throw 'EndToEnd requires real SKK-JISYO.L via -LargeDictionary'}
    Gate 'ctest' 'ctest' @('--test-dir',(Join-Path $root $BuildDir),'-C','Release')
    $env:DDSKK_HARNESS_DIAGNOSTICS='1'
    $paths=@('-RepositoryPath',$root,'-DllPath',(Join-Path $bin 'ddskk-ime.dll'),
      '-TsfHostExe',(Join-Path $bin 'tsf-host.exe'),'-EngineHostPath',(Join-Path $bin 'ddskk-engine-host.exe'),
      '-EngineExecutablePath',$Runtime,'-ColdLoadSleepSec','45')
    ScriptGate 'test-ddskk-behavior' $paths
    ScriptGate 'test-emacs-integration' $paths
    $env:HOME=[Environment]::GetFolderPath('UserProfile')
    Gate 'inline-emacs' 'python' @((Join-Path $PSScriptRoot 'test-inline-preedit.py'),
      '--dll',(Join-Path $bin 'ddskk-ime.dll'),'--core',(Join-Path $bin 'ddskk-ime-core.dll'),
      '--tsf-host',(Join-Path $bin 'tsf-host.exe'),'--engine-host',(Join-Path $bin 'ddskk-engine-host.exe'),
      '--runtime',$Runtime,'--artifacts',(Join-Path $run 'inline-emacs'),'--case','emacs','--cold-load','45','--repository',$root)
    foreach($name in @('test-engine-session-v2','test-engine-learning-v2',
      'test-engine-learning-crash-v2','test-engine-provider-outbox-v2','test-sk1-provider-relay','test-sk1-skkserv',
      'test-local-conversion','test-local-two-source','test-local-navigation','test-local-overlay',
      'test-local-key-refusal','test-local-fallback','test-local-idle-spool','test-local-cleanup')) {
      ScriptGate $name $common
    }
    foreach($name in @('test-local-edit-recovery','test-local-state-stress')) {
      ScriptGate $name ($common+@('-LargeDictionary',$LargeDictionary))
    }
    ScriptGate 'test-private-pipe-soak' $common
  }
}
Write-Output "PASS S2 stage=$Stage gates=$checks artifacts=$run"
