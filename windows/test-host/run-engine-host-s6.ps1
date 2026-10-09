[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [ValidateSet('Qualification','Resources','Production','Os1')][string]$Stage='Qualification',
      [string]$BuildDir='build/w', [string]$LargeDictionary='', [string]$LargeDictionaryUtf8='',
      [int]$ColdLoadSleepSec=45, [ValidateRange(1,1)][int]$MatrixWorkers=1,
      [switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path $root ($BuildDir+'/s6-'+[guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($run).StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)) {
  throw 'S6 artifacts must be under this worktree build directory'
}
[void](New-Item -ItemType Directory $run)
$results=@()
$dictionary=$null
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
  $script:results+=@{name=$name;command=@($exe)+$arguments;exit=$code;log=$log;sha256=(Get-FileHash $log).Hash}
  if($code -ne 0){throw "FAIL S6 $name exit=$code log=$log"}
}
function ScriptGate([string]$name,[string[]]$extra=@()) {
  Gate $name 'pwsh' (@('-NoProfile','-File',(Join-Path $PSScriptRoot ($name+'.ps1')),
    '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-ColdLoadSleepSec',"$ColdLoadSleepSec")+$extra)
}
function Os1Gates {
  foreach($mode in @('pipe','dns')) {
    Gate ("os1-"+$mode) 'python' @((Join-Path $PSScriptRoot 'test-os1-private.py'),
      '--runtime',$Runtime,'--host',(Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"),
      '--build-dir',$BuildDir,'--cold-load-sleep-sec',"$ColdLoadSleepSec",'--mode',$mode)
  }
}
$saved=@{}
foreach($name in @('SOURCES','CACHE','RESTART','PUBLICATION','LEARNING','SHADOW')) {
  $variable='DDSKK_HOST_POLICY_'+$name
  $saved[$variable]=[Environment]::GetEnvironmentVariable($variable)
  [Environment]::SetEnvironmentVariable($variable,$(if($name -eq 'SHADOW'){'0'}else{'1'}))
}
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
    Gate 'exact-policy-artifact' 'python' @((Join-Path $PSScriptRoot 'host-windows-s6.py'),
      '--runtime',$Runtime,'--output',(Join-Path $run 'runtime.json'),'--samples','3',
      '--cold-load-sleep-sec',"$ColdLoadSleepSec")
    Gate 'native-units' 'ctest' @('--test-dir',(Join-Path $root $BuildDir),'-C','Release','--output-on-failure','-j','1')
    ScriptGate 'test-private-pipe-soak'
    Gate 'mmap-flush-event-jobs' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'run-engine-host-s4.ps1'),
      '-Runtime',$Runtime,'-BuildDir',$BuildDir,'-Stage','Recovery','-ColdLoadSleepSec',"$ColdLoadSleepSec",'-MatrixWorkers','1')
    ScriptGate 'test-sk1-skkserv'
    ScriptGate 'test-sk1-provider-relay'
    Os1Gates
    # ACL denial/client CancelIoEx have real probes; low-IL compatibility,
    # server cancellation and synchronous resolver cancellation remain open.
    # Do not turn the remaining OS1 acceptance gaps into an aggregate PASS.
    if(-not $ValidateParametersOnly){throw 'INCOMPLETE S6 OS1: low-IL/server-cancel compatibility and DNS cancellation remain unqualified; retain native (see S6 decision table)'}
  } else {
    $qualifiedDictionary=$LargeDictionary
    if(-not $ValidateParametersOnly -or ($LargeDictionary -and (Test-Path -LiteralPath $LargeDictionary))) {
      if(-not $LargeDictionary){throw 'Production requires a content-validated L dictionary via -LargeDictionary'}
      $select=@((Join-Path $PSScriptRoot 'large-dictionary.py'),'--dictionary',$LargeDictionary)
      if($LargeDictionaryUtf8){$select+=@('--utf8-copy',$LargeDictionaryUtf8)}
      $json=& python @select
      if($LASTEXITCODE -ne 0){throw 'L dictionary content/encoding validation failed'}
      $dictionary=$json | ConvertFrom-Json
      $qualifiedDictionary=$dictionary.utf8.path
      Write-Output ("DICTIONARY "+($dictionary | ConvertTo-Json -Depth 5 -Compress))
    }
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
    if(-not $ValidateParametersOnly){throw 'INCOMPLETE S6 Production: serial pressure gates are not simultaneous GC/network/storage pressure across the bundle cycle; see S6 decision section'}
  }
  if($ValidateParametersOnly){Write-Output "PASS S6 $Stage parameter audit gates=$($results.Count) stacks=0"}
  else {Write-Output "PASS S6 stage=$Stage gates=$($results.Count) artifacts=$run"}
} finally {
  foreach($variable in $saved.Keys){[Environment]::SetEnvironmentVariable($variable,$saved[$variable])}
  @{stage=$Stage;runtime_sha256=(Get-FileHash -LiteralPath $Runtime).Hash;dictionary=$dictionary;gates=$results} |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $run 'evidence.json') -Encoding utf8
}
