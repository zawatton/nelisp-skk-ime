[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][string]$LargeDictionary,
      [string]$BuildDir='build/w', [string]$CoreDll='',
      [int]$ColdLoadSleepSec=45,
      [ValidateSet('all','denied','swap','provider-denied','registration-loss','focus-swap')][string]$Only='all')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('lf3-edit-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$personal=Join-Path $run 'synthetic-personal.utf8'
[IO.File]::WriteAllText($personal,"ていこうち /抵抗値/`nあたい /値/`nおーむ /Ω/オーム/`nかな /仮名/`nあたい /値/`nていこうち /抵抗値/`nおーむ /Ω/オーム/`nかな /仮名/`nあたい /値/`nていこうち /抵抗値/`n",(New-Object Text.UTF8Encoding($false)))
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LOCAL_WORKER_STALL_MS')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
if(-not $CoreDll){$CoreDll=Join-Path $build 'Release/ddskk-ime-core.dll'}
try {
 $env:DDSKK_DICTIONARY_FILES=$personal+';'+[IO.Path]::GetFullPath($LargeDictionary)
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'; $env:NATIVEIME_TEST_LOCAL_WORKER_STALL_MS='5000'
 $cases=@(
  @{name='denied'; failure='none'; script='CTX2 a i SPACE WAIT3000 ENTER CTX1 T e i k o u c h i REFUSEWRITE SPACE WAIT200 SETTLE8000:DENIED SETTLE8000:RETRY ENTER SETTLE8000:END'; expected='抵抗値'},
  @{name='swap'; failure='none'; script='CTX2 a i SPACE WAIT3000 ENTER CTX1 T e i k o u c h i SPACE CORE:B ENTER WAIT100 T e i k o u t i SPACE ENTER WAIT6500 CORE:production WAIT1000 T e i k o u c h i SPACE ENTER WAIT6500 CORE:bad-init WAIT1500 T e i k o u t i SPACE ENTER WAIT6500 SETTLE8000:END'; expected='抵抗値抵抗値抵抗値抵抗値'},
  @{name='provider-denied'; failure='corrupt'; script='CTX2 a i SPACE WAIT3000 ENTER CTX1 A t a i SPACE SETTLE8000:FIRST REFUSEWRITE SPACE SETTLE8000:DENIED SPACE SETTLE8000:RETRY ENTER SETTLE8000:END'; expected='値'},
  @{name='registration-loss'; failure='none'; script='CTX2 a i SPACE WAIT3000 ENTER CTX1 T e i k o u c h i SPACE SPACE SETTLE8000:REG KILLHOST ENTER SETTLE8000:RESOLVED CTRLG K a n j i SPACE ENTER SETTLE8000:END'; expected='漢字'},
  @{name='focus-swap'; failure='none'; script='CTX2 a i SPACE WAIT3000 ENTER CTX1 T e i k o u c h i SPACE CTX2 K a n j i SPACE ENTER CTX1 SETTLE8000:END'; expected='抵抗値'})
 foreach($case in @($cases | Where-Object {$Only -eq 'all' -or $_.name -eq $Only})) {
  $log=Join-Path $run ($case.name+'.log')
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
   -Script $case.script -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
   -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath $CoreDll `
   -CoreTestDirectory (Join-Path $build 'Release') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') `
   -LocalConversion 1 -LocalIndexFailure $case.failure -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run $case.name) *> $log
  if($LASTEXITCODE -ne 0){throw "Harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  if($text -match 'SETTLE TIMEOUT' -or $text -notmatch ('AFTER END BUF=\['+[regex]::Escape($case.expected)+'\] SEL=.* COMP=-')){throw "Conversion did not commit: $log"}
  if($case.name -eq 'denied' -and ($text -notmatch 'EDIT_REFUSED flags=' -or $text -notmatch 'AFTER DENIED BUF=\[▼抵抗値\]' -or $text -notmatch 'LOCAL_EDIT recovered=1' -or $text -notmatch 'AFTER RETRY BUF=\[▼抵抗値\]')){throw "Denied edit stranded controller ownership: $log"}
  if($case.name -eq 'swap' -and ($text -notmatch 'LOCAL_WORKER stalled_ms=5000' -or $text -notmatch 'CORE swapped version=B' -or $text -notmatch 'CORE swapped version=production' -or $text -notmatch 'CORE reject-init')){throw "Pending-learning core swap not exercised: $log"}
  if($case.name -eq 'provider-denied' -and ($text -notmatch 'EDIT_REFUSED flags=' -or $text -notmatch 'LOCAL_FALLBACK resolved=reading pending=0' -or $text -notmatch 'AFTER DENIED BUF=\[▽あたい\]' -or $text -notmatch 'AFTER RETRY BUF=\[▼値\]')){throw "Provider edit denial not resolved: $log"}
  if($case.name -eq 'registration-loss' -and ($text -notmatch 'branch=registration-async-control' -or $text -notmatch 'LOCAL_FALLBACK resolved=reading pending=0')){throw "Registration ownership not recovered: $log"}
  if($case.name -eq 'focus-swap' -and $text -notmatch 'AFTER ENTER BUF=\[あい漢字\] SEL=4,4 COMP=-'){throw "Focus commit lost/duplicated text: $log"}
  $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
  $maximum=($times | Measure-Object -Maximum).Maximum
  if(-not $times.Count -or $maximum -gt 25000){throw "Callback watchdog exceeded 25000 us: $maximum log=$log"}
  Write-Output "PASS local edit recovery case=$($case.name) callbacks=$($times.Count) max_us=$maximum log=$log"
 }
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
