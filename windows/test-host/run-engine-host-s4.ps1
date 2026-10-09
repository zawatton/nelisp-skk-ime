[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [string]$ControlBuildDir='build/policy-control',
      [ValidateSet('Equivalence','Publication','Recovery','EndToEnd')][string]$Stage='Equivalence',
      [string]$LargeDictionary='',[int]$ColdLoadSleepSec=45,
      [ValidateRange(1,1)][int]$MatrixWorkers=1,
      [switch]$ContinueOnFailure)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path $root ($BuildDir+'/s4-gates-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$checks=0
$attempts=0
$failures=@()
$names=@('DDSKK_HOST_POLICY_SOURCES','DDSKK_HOST_POLICY_CACHE','DDSKK_HOST_POLICY_RESTART',
  'DDSKK_HOST_POLICY_PUBLICATION','DDSKK_HOST_POLICY_LEARNING','DDSKK_HOST_POLICY_TEST_PAUSE_KIND',
  'DDSKK_HOST_POLICY_SHADOW','HOME','NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function Gate([string]$name,[string]$exe,[string[]]$arguments) {
  $before=@(Get-Process nelisp,ddskk-engine-host,tsf-host -ErrorAction SilentlyContinue | ForEach-Object Id)
  $log=Join-Path $run ("$attempts-$name.log");$script:attempts++
  Write-Output ("cmd: $exe "+($arguments -join ' '))
  & $exe @arguments *> $log
  $code=$LASTEXITCODE;Get-Content -LiteralPath $log -Tail 8
  $remaining=@(Get-Process nelisp,ddskk-engine-host,tsf-host -ErrorAction SilentlyContinue |
    Where-Object {$before -notcontains $_.Id})
  if($remaining.Count){
    $attribution=& python (Join-Path $PSScriptRoot 'host-test-process-guard.py') --root $root @($remaining.Id)
    if($LASTEXITCODE -ne 0){throw "Process attribution failed after $name"}
    $owned=$attribution | ConvertFrom-Json
    if($owned.external.Count){Write-Output "GUARD unrelated processes left untouched: $($owned.external -join ',')"}
    $remaining=@($remaining | Where-Object {$owned.remaining -contains $_.Id})
  }
  if($remaining.Count){throw "Refuse next stack: new IME processes remain after $name ($($remaining.Id -join ','))"}
  if($code -ne 0){
    $failure="FAIL $name exit=$code log=$log"
    if(-not $ContinueOnFailure){throw $failure}
    $script:failures+=$failure;Write-Output $failure;return
  }
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
  # Positive timing samples must not inherit a private fault injection from
  # the invoking shell. The original value is restored by finally.
  Remove-Item Env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS -ErrorAction SilentlyContinue
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
  } elseif($Stage -in @('Publication','Recovery')) {
    Gate 'publication' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'publication')+$common)
    $env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS='1500'
    $log=Join-Path $run 'publication-negative.log'
    Write-Output 'cmd (expected timing failure): host-policy-s4.py publication; private publication stall=1500 ms'
    & python (Join-Path $PSScriptRoot 'host-policy-s4.py') publication @common *> $log
    $code=$LASTEXITCODE
    $output=Get-Content -LiteralPath $log -Raw
    $rejection=($output -split "`n" | Where-Object {$_ -match '^FAIL S4 publication .*"samples": 21'} | Select-Object -Last 1)
    $measured=if($rejection){($rejection -replace '^FAIL S4 publication ','') | ConvertFrom-Json}else{$null}
    if($code -eq 0 -or -not $measured -or $measured.p99 -le 500 -or $measured.max -le 1000 -or $output -notmatch 'leftovers=\[\]') {
      throw "Real publication stall control did not fail the timing gate: $log"
    }
    Write-Output "CONTROL expected timing rejection: $($rejection.Trim()); raw log=$log"
    $checks++;Write-Output 'PASS real publication stall rejected by identical timing gate'
    Remove-Item Env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS
    if($Stage -eq 'Recovery') {
      Gate 'matrix' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'matrix','--workers',"$MatrixWorkers")+$common)
      foreach($name in @('test-engine-learning-crash-v2','test-engine-provider-outbox-v2')) {
        Gate $name 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot ($name+'.ps1')),
          '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
      }
    }
  } else {
    if(-not $LargeDictionary -or -not (Test-Path -LiteralPath $LargeDictionary)){
      $failure='EndToEnd requires real SKK-JISYO.L via -LargeDictionary'
      if(-not $ContinueOnFailure){throw $failure}
      $failures+=$failure;Write-Output "FAIL $failure"
    }
    $env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND='9'
    $bin=Join-Path $root "$BuildDir/Release"
    Write-Output 'KNOWN_RED excluded lattice-behavior: Claude main/native switches-OFF control failed 2/2 (provider control >20 ms; warm first candidate >150 ms). Evidence: docs/contracts/CLAUDE-S4.org. Standalone test and thresholds retained; exclusion authorized 2026-10-09.'
    $existing=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-engine-host-s3.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ControlBuildDir',$ControlBuildDir,
      '-Stage','EndToEnd')
    if($LargeDictionary){$existing+=@('-LargeDictionary',$LargeDictionary)}
    if($ContinueOnFailure){$existing+='-ContinueOnFailure'}
    Gate 'existing-end-to-end' 'pwsh' $existing
    $callback=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-host-policy-callbacks.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
    Gate 'callback-io' 'pwsh' $callback
    $log=Join-Path $run 'callback-negative.log'
    & pwsh @callback -NegativeControl *> $log
    $code=$LASTEXITCODE;Get-Content -LiteralPath $log -Tail 8
    if($code -eq 0 -or (Get-Content -LiteralPath $log -Raw) -notmatch 'FAIL S4 callback pipe_io=\d+ blocking_waits=[1-9]') {
      $failure="Synchronous callback wait control was not rejected by the probe: $log"
      if(-not $ContinueOnFailure){throw $failure}
      $failures+=$failure;Write-Output "FAIL $failure"
    } else {
      $checks++;Write-Output 'PASS real callback wait rejected by identical IO gate'
    }
    Remove-Item Env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND -ErrorAction SilentlyContinue
    Gate 'multi-client' 'python' (@((Join-Path $PSScriptRoot 'host-policy-s4.py'),'clients')+$common)
    ERT 'stateline-ert' @('-l',(Join-Path $root 'framework/test/nelisp-ime-stateline-test.el'),
      '-l',(Join-Path $root 'framework/test/nelisp-ime-stateline-conformance-test.el'))
    ERT 'lattice-ert' @('-l',(Join-Path $root 'engines/lattice/test/nelisp-ime-lattice-test.el'))
  }
  if($failures.Count){throw "FAIL S4 stage=$Stage passed=$checks failures=$($failures.Count) artifacts=$run"}
  Write-Output "PASS S4 stage=$Stage gates=$checks artifacts=$run"
} finally {
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
