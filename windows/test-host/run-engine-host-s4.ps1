[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [string]$ControlBuildDir='build/policy-control',
      [ValidateSet('Equivalence','Recovery','EndToEnd')][string]$Stage='Equivalence',
      [string]$LargeDictionary='',[int]$ColdLoadSleepSec=45,
      [ValidateRange(1,3)][int]$MatrixWorkers=3)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path $root ($BuildDir+'/s4-gates-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$checks=0
$names=@('DDSKK_HOST_POLICY_SOURCES','DDSKK_HOST_POLICY_CACHE','DDSKK_HOST_POLICY_RESTART',
  'DDSKK_HOST_POLICY_PUBLICATION','DDSKK_HOST_POLICY_LEARNING','DDSKK_HOST_POLICY_TEST_PAUSE_KIND',
  'DDSKK_HOST_POLICY_SHADOW','HOME','NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function Gate([string]$name,[string]$exe,[string[]]$arguments) {
  $log=Join-Path $run ("$checks-$name.log")
  Write-Output ("cmd: $exe "+($arguments -join ' '))
  & $exe @arguments *> $log
  $code=$LASTEXITCODE;Get-Content -LiteralPath $log -Tail 8
  if($code -ne 0){throw "FAIL $name exit=$code log=$log"}
  $script:checks++
}
function ERT([string]$name,[string[]]$loads) {
  $env:HOME=[Environment]::GetFolderPath('UserProfile')
  Gate $name 'emacs' (@('-Q','--batch','-L',$root,'-L',(Join-Path $root 'framework/src'),
    '-L',(Join-Path $root 'engines/lattice/src'))+$loads+@('-f','ert-run-tests-batch-and-exit'))
}
$common=@('--runtime',$Runtime,'--host',(Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"),
  '--build-dir',$BuildDir,'--cold-load-sleep-sec',"$ColdLoadSleepSec")
try {
  foreach($name in $names[0..4]){[Environment]::SetEnvironmentVariable($name,'1')}
  $env:DDSKK_HOST_POLICY_SHADOW='0'
  Gate 'negative-controls' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'controls')+$common)
  if($Stage -eq 'Equivalence') {
    Gate 'control-config' 'cmake' @('-S',(Join-Path $PSScriptRoot 's3'),'-B',(Join-Path $root $ControlBuildDir),'-G','Visual Studio 17 2022','-A','x64')
    Gate 'control-build' 'cmake' @('--build',(Join-Path $root $ControlBuildDir),'--config','Release')
    Gate 'authority-unit' (Join-Path $root "$ControlBuildDir/Release/host-policy-unit.exe") @()
    Gate 'callback-probe-unit' (Join-Path $root "$ControlBuildDir/Release/callback-io-unit.exe") @(
      (Join-Path $root "$ControlBuildDir/Release/callback-io-fixture.dll"))
    Gate 'recorded-equivalence' 'python' @((Join-Path $PSScriptRoot 'host-policy-ipc.py'),'--runtime',$Runtime,
      '--records',(Join-Path $root 'docs/contracts/host-policy-inputs-v2.json'))
    ERT 'policy-ert' @('-l',(Join-Path $PSScriptRoot 'host-policy-test.el'))
    Gate 'source-and-fixture-integrity' 'python' @((Join-Path $PSScriptRoot 'verify-host-contracts.py'))
    # Native replay, each responsibility alone, and all responsibilities together.
    foreach($selected in @('OFF','SOURCES','CACHE','RESTART','PUBLICATION','LEARNING','ALL')) {
      foreach($name in $names[0..4]) {
        $on=$selected -eq 'ALL' -or $name -eq ('DDSKK_HOST_POLICY_'+$selected)
        [Environment]::SetEnvironmentVariable($name, $(if($on){'1'}else{'0'}))
      }
      foreach($engine in @('ddskk','lattice')) {
        $fixture=$(if($engine -eq 'ddskk'){'native-v1.json'}else{'native-legacy-v1.json'})
        Gate "replay-$selected-$engine" 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-host-contracts.ps1'),
          '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec",
          '-Engine',$engine,'-Fixture',"docs/contracts/$fixture")
      }
    }
  } elseif($Stage -eq 'Recovery') {
    Gate 'publication' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'publication')+$common)
    $env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS='1500'
    $log=Join-Path $run 'publication-negative.log'
    & python (Join-Path $PSScriptRoot 'host-policy-s4.py') publication @common *> $log
    $code=$LASTEXITCODE; Get-Content -LiteralPath $log -Tail 8
    $output=Get-Content -LiteralPath $log -Raw
    if($code -eq 0 -or $output -notmatch 'FAIL S4 publication' -or $output -notmatch 'leftovers=\[\]') {
      throw "Real publication stall control did not fail the timing gate: $log"
    }
    $checks++;Write-Output 'PASS real publication stall rejected by identical timing gate'
    Remove-Item Env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS
    Gate 'matrix' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'matrix','--workers',"$MatrixWorkers")+$common)
    foreach($name in @('test-engine-learning-crash-v2','test-engine-provider-outbox-v2')) {
      Gate $name 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot ($name+'.ps1')),
        '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
    }
  } else {
    if(-not $LargeDictionary -or -not (Test-Path -LiteralPath $LargeDictionary)){throw 'EndToEnd requires real SKK-JISYO.L via -LargeDictionary'}
    $env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND='9'
    $bin=Join-Path $root "$BuildDir/Release"
    Gate 'lattice-behavior' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-lattice-behavior.ps1'),
      '-RepositoryPath',$root,'-DllPath',(Join-Path $bin 'ddskk-ime.dll'),
      '-TsfHostExe',(Join-Path $bin 'tsf-host.exe'),'-EngineHostPath',(Join-Path $bin 'ddskk-engine-host.exe'),
      '-EngineExecutablePath',$Runtime,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
    Gate 'existing-end-to-end' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-engine-host-s3.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ControlBuildDir',$ControlBuildDir,
      '-Stage','EndToEnd','-LargeDictionary',$LargeDictionary)
    $callback=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-host-policy-callbacks.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
    Gate 'callback-io' 'pwsh' $callback
    $log=Join-Path $run 'callback-negative.log'
    & pwsh @callback -NegativeControl *> $log
    $code=$LASTEXITCODE;Get-Content -LiteralPath $log -Tail 8
    if($code -eq 0 -or (Get-Content -LiteralPath $log -Raw) -notmatch 'FAIL S4 callback pipe_io=\d+ blocking_waits=[1-9]') {
      throw "Synchronous callback wait control was not rejected by the probe: $log"
    }
    $checks++;Write-Output 'PASS real callback wait rejected by identical IO gate'
    Remove-Item Env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND -ErrorAction SilentlyContinue
    Gate 'multi-client' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'clients')+$common)
    ERT 'stateline-ert' @('-l',(Join-Path $root 'framework/test/nelisp-ime-stateline-test.el'),
      '-l',(Join-Path $root 'framework/test/nelisp-ime-stateline-conformance-test.el'))
    ERT 'lattice-ert' @('-l',(Join-Path $root 'engines/lattice/test/nelisp-ime-lattice-test.el'))
  }
  Write-Output "PASS S4 stage=$Stage gates=$checks artifacts=$run"
} finally {
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
