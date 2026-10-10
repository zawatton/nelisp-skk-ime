[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [ValidateSet('Qualification','Resources','Production','Os1','NativeBaseline')][string]$Stage='Qualification',
      [string]$BuildDir='build/w', [string]$LargeDictionary='', [string]$LargeDictionaryUtf8='',
      [int]$ColdLoadSleepSec=45, [ValidateRange(1,1)][int]$MatrixWorkers=1,
      [switch]$ValidateParametersOnly, [switch]$ConcurrentPressureOnly,
      [string]$SubstrateSource='')
$ErrorActionPreference='Stop'
if($ConcurrentPressureOnly -and $Stage -ne 'Production'){throw '-ConcurrentPressureOnly requires -Stage Production'}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path $root ($BuildDir+'/s6-'+[guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($run).StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)) {
  throw 'S6 artifacts must be under this worktree build directory'
}
[void](New-Item -ItemType Directory $run)
$results=@()
$dictionary=$null
$coverage=@()
$stageStatus='incomplete'
function Gate([string]$name,[string]$exe,[string[]]$arguments) {
  if($exe -eq 'pwsh') {
    $index=[Array]::IndexOf($arguments,'-File')
    $metadata=Get-Command $arguments[$index+1] -ErrorAction Stop
    for($i=$index+2;$i -lt $arguments.Count;$i++) {
      if($arguments[$i].StartsWith('-')) {
        $parameter=$arguments[$i].Substring(1)
        if(-not $metadata.Parameters.ContainsKey($parameter)){throw "Unknown $name parameter -$parameter"}
        if($metadata.Parameters[$parameter].ParameterType -ne [switch]){$i++}
      }
    }
  }
  if($ValidateParametersOnly){$script:results+=@{name=$name;command=@($exe)+$arguments;status='parameter audit only'};return}
  $log=Join-Path $run ("$($results.Count)-"+$name+'.log')
  Write-Output ("cmd: $exe "+($arguments -join ' '))
  & python (Join-Path $PSScriptRoot 'host-test-process-guard.py') run --root $root -- $exe @arguments *> $log
  $code=$LASTEXITCODE
  Get-Content -LiteralPath $log -Tail 8
  $script:results+=@{name=$name;command=@($exe)+$arguments;exit=$code;status=$(if($code -eq 0){'PASS'}else{'FAIL'});log=$log;sha256=(Get-FileHash $log).Hash}
  if($code -ne 0){throw "FAIL S6 $name exit=$code log=$log"}
}
function ScriptGate([string]$name,[string[]]$extra=@()) {
  Gate $name 'pwsh' (@('-NoProfile','-File',(Join-Path $PSScriptRoot ($name+'.ps1')),
    '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")+$extra)
}
function Os1Gates([switch]$IncludeDictionary) {
  $modes=@('pipe','dns')
  if($IncludeDictionary){$modes+='dictionary'}
  foreach($mode in $modes) {
    $extra=@()
    if($mode -eq 'dictionary'){$extra=@('--dictionary',$dictionary.utf8.path)}
    Gate ("os1-"+$mode) 'python' (@((Join-Path $PSScriptRoot 'test-os1-private.py'),
      '--runtime',$Runtime,'--host',(Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"),
      '--build-dir',$BuildDir,'--cold-load-sleep-sec',"$ColdLoadSleepSec",'--mode',$mode)+$extra)
  }
}
function SelectLargeDictionary {
  if(-not $LargeDictionary){throw "$Stage requires a content-validated L dictionary via -LargeDictionary"}
  $select=@((Join-Path $PSScriptRoot 'large-dictionary.py'),'--dictionary',$LargeDictionary)
  if($LargeDictionaryUtf8){$select+=@('--utf8-copy',$LargeDictionaryUtf8)}
  $json=& python @select
  if($LASTEXITCODE -ne 0){throw 'L dictionary content/encoding validation failed'}
  $script:dictionary=$json | ConvertFrom-Json
  Write-Output ("DICTIONARY "+($dictionary | ConvertTo-Json -Depth 5 -Compress))
}
function AssertOs1Coverage([string]$DesignText='') {
  # The table is the component inventory and gate mapping, not a second list
  # that could silently drift. Audit receipts are never execution evidence.
  $design=if($DesignText){$DesignText}else{[IO.File]::ReadAllText((Join-Path $root 'docs/design/engine-host-nelisp.org'))}
  $table=[regex]::Match($design,'(?m)^\| OS1 component \|[^\r\n]*\r?\n(?:\|[^\r\n]*(?:\r?\n|$))+')
  if(-not $table.Success){throw 'Missing S6 OS1 decision table'}
  $rows=@(($table.Value.TrimEnd() -split '\r?\n') | Select-Object -Skip 2)
  if($rows.Count -ne 7){throw 'S6 decision table must contain seven OS1 components'}
  $expectedStatus=$(if($ValidateParametersOnly){'parameter audit only'}else{'PASS'})
  foreach($row in $rows) {
    $fields=$row.Split('|')
    $component=$fields[1].Trim()
    $names=@($fields[3].Trim() -split ',\s*' | Where-Object {$_})
    if(-not $names.Count){throw "OS1 component has no gate: $component"}
    foreach($name in $names) {
      $match=@($results | Where-Object {$_.name -eq $name -and $_.status -eq $expectedStatus})
      if(-not $match.Count){throw "OS1 component $component has no successful gate $name"}
    }
    $script:coverage+=@{component=$component;gates=$names;executed=(-not $ValidateParametersOnly)}
  }
}
$saved=@{}
$policyEnabled=$Stage -in @('Resources','Production')
foreach($name in @('SOURCES','CACHE','RESTART','PUBLICATION','LEARNING','SHADOW')) {
  $variable='DDSKK_HOST_POLICY_'+$name
  $saved[$variable]=[Environment]::GetEnvironmentVariable($variable)
  [Environment]::SetEnvironmentVariable($variable,$(if($policyEnabled -and $name -ne 'SHADOW'){'1'}else{'0'}))
}
foreach($variable in @('DDSKK_HOST_POLICY_TEST_PAUSE_KIND','HOME')) {
  $saved[$variable]=[Environment]::GetEnvironmentVariable($variable)
}
Remove-Item Env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND -ErrorAction SilentlyContinue
$env:HOME=[Environment]::GetFolderPath('UserProfile')
try {
  if($Stage -eq 'Os1') {
    Os1Gates
  } elseif($Stage -eq 'Resources') {
    Gate 'exact-policy-artifact' 'python' @((Join-Path $PSScriptRoot 'host-windows-s6.py'),
      '--runtime',$Runtime,'--output',(Join-Path $run 'runtime.json'),'--samples','3',
      '--cold-load-sleep-sec',"$ColdLoadSleepSec")
    # Real adapter tails, policy pause/kill, not just standalone IPC timing.
    ScriptGate 'test-private-pipe-soak'
    ScriptGate 'test-host-policy'
    ScriptGate 'test-host-policy' @('-Mode','soak')
  } elseif($Stage -eq 'Qualification') {
    SelectLargeDictionary
    Os1Gates -IncludeDictionary
    Gate 'os1-unicode' 'python' @((Join-Path $PSScriptRoot 'test-os1-unicode.py'),
      '--runtime',$Runtime,'--output',(Join-Path $run 'unicode.json'),
      '--cold-load-sleep-sec',"$ColdLoadSleepSec")
    ScriptGate 'test-private-pipe-soak'
    ScriptGate 'test-sk1-skkserv'
    ScriptGate 'test-sk1-provider-relay'
    ScriptGate 'test-local-cleanup'
    ScriptGate 'test-engine-learning-crash-v2'
    ScriptGate 'test-engine-provider-outbox-v2'
    ScriptGate 'test-host-policy-callbacks'
    AssertOs1Coverage
  } elseif($Stage -eq 'NativeBaseline') {
    SelectLargeDictionary
    # Reuse native gates directly. S3/S4 aggregate runners force policy ON.
    ScriptGate 'test-local-conversion'
    ScriptGate 'test-local-state-stress' @('-LargeDictionary',$dictionary.utf8.path)
    ScriptGate 'test-local-edit-recovery' @('-LargeDictionary',$dictionary.utf8.path)
    Gate 'inline-emacs' 'python' @((Join-Path $PSScriptRoot 'test-inline-preedit.py'),
      '--dll',(Join-Path $root "$BuildDir/Release/ddskk-ime.dll"),
      '--core',(Join-Path $root "$BuildDir/Release/ddskk-ime-core.dll"),
      '--tsf-host',(Join-Path $root "$BuildDir/Release/tsf-host.exe"),
      '--engine-host',(Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"),
      '--runtime',$Runtime,'--artifacts',(Join-Path $run 'inline-emacs'),
      '--case','emacs','--cold-load',"$ColdLoadSleepSec",'--repository',$root)
    ScriptGate 'test-engine-learning-crash-v2'
    ScriptGate 'test-engine-provider-outbox-v2'
    ScriptGate 'test-local-cleanup'
    ScriptGate 'test-private-pipe-soak'
    ScriptGate 'test-host-policy-callbacks'
  } else {
    $qualifiedDictionary=$LargeDictionary
    if(-not $ValidateParametersOnly -or ($LargeDictionary -and (Test-Path -LiteralPath $LargeDictionary))) {
      SelectLargeDictionary
      $qualifiedDictionary=$dictionary.utf8.path
    }
    if(-not $ConcurrentPressureOnly){
    ScriptGate 'test-private-host-bundle' @('-Stage','Recovery')
    Gate 'production-clients' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-private-host-bundle.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-Stage','EndToEnd','-ColdLoadSleepSec',"$ColdLoadSleepSec",
      '-LargeDictionary',$qualifiedDictionary,'-Clients','3')
    Gate 'val1-pressure' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-engine-host-s4.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-Stage','EndToEnd','-LargeDictionary',$qualifiedDictionary,
      '-ColdLoadSleepSec',"$ColdLoadSleepSec",'-MatrixWorkers','1')
    # Recovery checks actual acknowledged IDs; callbacks includes the real
    # synchronous-wait rejection. Neither threshold is changed by this runner.
    Gate 'val1-durability' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-engine-host-s4.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-Stage','Recovery',
      '-ColdLoadSleepSec',"$ColdLoadSleepSec",'-MatrixWorkers','1')
    }
    $concurrentExtra=@('-LargeDictionary',$qualifiedDictionary)
    if($SubstrateSource){$concurrentExtra+=@('-SubstrateSource',$SubstrateSource)}
    ScriptGate 'test-concurrent-pressure' $concurrentExtra
  }
  $stageStatus=$(if($ValidateParametersOnly){'parameter audit only'}elseif($ConcurrentPressureOnly){'PASS concurrent gate only'}else{'PASS'})
  if($ValidateParametersOnly){Write-Output "PASS S6 $Stage parameter audit gates=$($results.Count) stacks=0"}
  elseif($ConcurrentPressureOnly){Write-Output "PASS S6 concurrent gate only gates=$($results.Count) serial_evidence=reused artifacts=$run"}
  else {Write-Output "PASS S6 stage=$Stage gates=$($results.Count) artifacts=$run"}
} catch {
  $stageStatus='FAIL'
  throw
} finally {
  foreach($variable in $saved.Keys){[Environment]::SetEnvironmentVariable($variable,$saved[$variable])}
  @{stage=$Stage;status=$stageStatus;runtime_sha256=(Get-FileHash -LiteralPath $Runtime).Hash;
    policy_enabled=$policyEnabled;dictionary=$dictionary;gates=$results;os1_coverage=$coverage;
    concurrent_pressure_only=[bool]$ConcurrentPressureOnly;serial_gates_executed=($Stage -eq 'Production' -and -not $ConcurrentPressureOnly -and -not $ValidateParametersOnly);
    serial_evidence_reused=[bool]$ConcurrentPressureOnly} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'evidence.json') -Encoding utf8
}
