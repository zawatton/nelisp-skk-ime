[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-fallback-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$saved=@{}
foreach($name in @('DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_CANDIDATE_CONTROL_FAIL_MS')) {$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'; $env:NATIVEIME_TEST_CANDIDATE_CONTROL_FAIL_MS='1600'
 foreach($failure in @('missing','corrupt')) {
  $log=Join-Path $run ($failure+'.log')
  # Own the harness before it runs, including DLL-spawned replacement hosts
  # after KILLHOST. Close only this case's job before the next case starts.
  & python (Join-Path $PSScriptRoot 'host-test-process-guard.py') run --root $root --cleanup -- powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
   -Script 'a i SPACE WAIT3000 ENTER K a n a SPACE SETTLE8000:FIRST KILLHOST SPACE SETTLE8000:RESOLVED CTRLG SETTLE8000:CANCEL K a n a SPACE SETTLE8000:RETRY CTRLG' `
   -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
   -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
   -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -LocalIndexFailure $failure `
   -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run $failure) *> $log
  if($LASTEXITCODE -ne 0){throw "Fallback harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  if($text -match 'SETTLE TIMEOUT' -or $text -notmatch 'LOCAL_FALLBACK resolved=reading pending=0' -or
     $text -notmatch 'SETTLE OK token=SETTLE8000:RESOLVED' -or $text -notmatch 'SETTLE OK token=SETTLE8000:RETRY') {throw "Provider stranded: $log"}
  $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
  $maximum=($times|Measure-Object -Maximum).Maximum
  if(-not $times.Count -or $maximum -gt 25000){throw "Callback exceeded 25000 us: $maximum log=$log"}
  Write-Output "PASS local fallback generation=$failure callbacks=$($times.Count) max_us=$maximum log=$log"
 }
 Write-Output 'PASS local fallback cases=2; failed control/engine loss/resolved ownership/retry; pending bound=5000 ms'
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
