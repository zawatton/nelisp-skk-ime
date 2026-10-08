[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [string]$ControlBuildDir='build/policy-control',
      [ValidateSet('Boundary','Isolation','Contracts','EndToEnd')][string]$Stage='Boundary',
      [string]$LargeDictionary='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$control=Join-Path $root "$ControlBuildDir/Release/host-policy-sync-control.exe"
$run=Join-Path $root ($BuildDir+'/s3-gates-'+[guid]::NewGuid().ToString('N'))
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
if($Stage -eq 'Boundary') {
  Gate 'control-config' 'cmake' @('-S',(Join-Path $PSScriptRoot 's3'),'-B',(Join-Path $root $ControlBuildDir),'-G','Visual Studio 17 2022','-A','x64')
  Gate 'control-build' 'cmake' @('--build',(Join-Path $root $ControlBuildDir),'--config','Release')
  Gate 'policy-unit' (Join-Path $root "$ControlBuildDir/Release/host-policy-unit.exe") @()
  Gate 'runtime-ipc' 'python' @((Join-Path $PSScriptRoot 'host-policy-ipc.py'),'--runtime',$Runtime)
  $env:HOME=[Environment]::GetFolderPath('UserProfile')
  Gate 'policy-ert' 'emacs' @('-Q','--batch','-L',$root,'-l',(Join-Path $PSScriptRoot 'host-policy-test.el'),'-f','ert-run-tests-batch-and-exit')
} elseif($Stage -eq 'Isolation') {
  ScriptGate 'test-host-policy' $common
  $log=Join-Path $run 'negative-control.log'
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-host-policy.ps1') @common -HostExecutable $control *> $log
  $code=$LASTEXITCODE; Get-Content -LiteralPath $log -Tail 12
  $text=Get-Content -LiteralPath $log -Raw
  if($code -eq 0 -or $text -notmatch 'FAIL pause isolation cached_max_ms=([0-9.]+)' -or [double]$Matches[1] -le 50 -or $text -notmatch 'leftovers=\[\]') {
    throw "Negative control was not rejected by latency gate: $log"
  }
  $checks++; Write-Output 'PASS synchronous control rejected by identical pause gate'
  ScriptGate 'test-host-policy' ($common+@('-Mode','soak'))
} elseif($Stage -eq 'Contracts') {
  foreach($shadow in @('0','1')) {
    $env:DDSKK_HOST_POLICY_SHADOW=$shadow
    ScriptGate 'test-host-contracts' $common
    ScriptGate 'test-host-contracts' ($common+@('-Engine','lattice','-Fixture','docs/contracts/native-legacy-v1.json'))
  }
} else {
  if(-not $LargeDictionary -or -not (Test-Path -LiteralPath $LargeDictionary)){throw 'EndToEnd requires real SKK-JISYO.L via -LargeDictionary'}
  $env:DDSKK_HOST_POLICY_SHADOW='1'
  if(-not $env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND){$env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND='5'}
  $env:DDSKK_HARNESS_DIAGNOSTICS='1'
  $env:HOME=[Environment]::GetFolderPath('UserProfile')
  Gate 'ctest' 'ctest' @('--test-dir',(Join-Path $root $BuildDir),'-C','Release')
  $paths=@('-RepositoryPath',$root,'-DllPath',(Join-Path $bin 'ddskk-ime.dll'),
    '-TsfHostExe',(Join-Path $bin 'tsf-host.exe'),'-EngineHostPath',(Join-Path $bin 'ddskk-engine-host.exe'),
    '-EngineExecutablePath',$Runtime,'-ColdLoadSleepSec','45')
  ScriptGate 'test-ddskk-behavior' $paths
  ScriptGate 'test-emacs-integration' $paths
  Gate 'inline-emacs' 'python' @((Join-Path $PSScriptRoot 'test-inline-preedit.py'),
    '--dll',(Join-Path $bin 'ddskk-ime.dll'),'--core',(Join-Path $bin 'ddskk-ime-core.dll'),
    '--tsf-host',(Join-Path $bin 'tsf-host.exe'),'--engine-host',(Join-Path $bin 'ddskk-engine-host.exe'),
    '--runtime',$Runtime,'--artifacts',(Join-Path $run 'inline-emacs'),'--case','emacs','--cold-load','45','--repository',$root)
  foreach($name in @('test-engine-session-v2','test-engine-learning-v2','test-engine-learning-crash-v2',
      'test-engine-provider-outbox-v2','test-sk1-provider-relay','test-sk1-skkserv',
      'test-local-conversion','test-local-two-source','test-local-navigation','test-local-overlay',
      'test-local-key-refusal','test-local-fallback','test-local-idle-spool','test-local-cleanup')) {
    ScriptGate $name $common
  }
  foreach($name in @('test-local-edit-recovery','test-local-state-stress')) {
    ScriptGate $name ($common+@('-LargeDictionary',$LargeDictionary))
  }
  Remove-Item Env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND -ErrorAction SilentlyContinue
  ScriptGate 'test-host-policy' $common
  ScriptGate 'test-host-policy' ($common+@('-Mode','soak'))
  # The coordinator must retain child/pause logs and existing KEYLAT evidence;
  # a passing ERT or pipe-only stage does not stand in for TSF callbacks.
}
Write-Output "PASS S3 stage=$Stage gates=$checks artifacts=$run"
