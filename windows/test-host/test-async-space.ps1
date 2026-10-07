[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('tl1-async-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$first=Join-Path $run 'first.utf8'; $second=Join-Path $run 'second.utf8'
[IO.File]::WriteAllText($first,"ない /無い/内/`nかな /仮名/佳奈/`n",$utf8)
[IO.File]::WriteAllText($second,"ない /無い/亡い/`nかな /仮名/加奈/`n",$utf8)
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS','NATIVEIME_TEST_LOCAL_MAP_DELAY_MS')) {
 $saved[$name]=[Environment]::GetEnvironmentVariable($name)
}
$checks=0
try {
 $env:DDSKK_DICTIONARY_FILES=$first+';'+$second
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 foreach($gap in @(0,10,20)) {
  $env:NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS='400'
  $env:NATIVEIME_TEST_LOCAL_MAP_DELAY_MS=$null
  $log=Join-Path $run ("gap-$gap.log")
  $keys="KEYGAP$gap WAIT1500 N a i ASYNCWRITE SPACE ASYNCFLUSH ASYNCWRITE ENTER N a i SPACE ENTER ASYNCFLUSH WAITREMAP5000 N a i SPACE ENTER SETTLE8000:END"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
   -Script $keys -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
   -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
   -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec -DebugLog -ArtifactDirectory (Join-Path $run "gap-$gap") *> $log
  if($LASTEXITCODE -ne 0){throw "Harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  foreach($pattern in @('EDIT_ASYNC queued=1','EDIT_ASYNC executed=1','AFTER ASYNCFLUSH BUF=\[▼無い\]','AFTER ASYNCFLUSH BUF=\[無い無い\].* COMP=-','AFTER END BUF=\[無い無い無い\].* COMP=-','LOCAL_MAPPING delay_ms=400 retained=1')) {
   if($text -notmatch $pattern){throw "Missing $pattern : $log"}; $checks++
  }
  if($text -match 'branch=provider-(queue|convert)|LOCAL_EDIT denied|LOCAL_EDIT recovered|SETTLE TIMEOUT') {throw "Local type-ahead waited for provider/timer: $log"}; $checks++
  $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
  $maximum=($times | Measure-Object -Maximum).Maximum
  if(-not $times.Count -or $maximum -gt 25000){throw "Callback watchdog exceeded 25000 us: $maximum : $log"}; $checks++
  $trace=(@(Get-ChildItem (Join-Path $run "gap-$gap") -Recurse -Filter dll-debug.log | ForEach-Object {[IO.File]::ReadAllText($_.FullName)})) -join "`n"
  foreach($phase in @('key-receipt','lookup-start','lookup-end','edit-request','edit-result','edit-start','edit-end','range-update-start','range-update-end','candidate-show-start','candidate-show-end')) {
   if($trace -notmatch "PHASE name=$phase seq=\d+"){throw "Missing diagnostic $phase : $log"}; $checks++
  }
  if($trace -notmatch 'PHASE name=edit-result .*async=1'){throw "TF_S_ASYNC not observed: $log"}; $checks++
  Write-Output "PASS async SPACE gap_ms=$gap callbacks=$($times.Count) max_us=$maximum checks=$checks log=$log"
 }
 # No mapped index initially: provider completion must replay a burst without
 # a per-character RPC. A later SPACE uses the newly mapped index.
 $env:NATIVEIME_TEST_LOCAL_MAP_DELAY_MS='1500'; $env:NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS=$null
 $log=Join-Path $run 'late.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
  -Script 'KEYGAP0 N a i SPACE ENTER K a n a ENTER SETTLE8000:BURST WAIT2000 N a i SPACE ASYNCWRITE ENTER ASYNCFLUSH SETTLE8000:END' `
  -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
  -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
  -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec -DebugLog -ArtifactDirectory (Join-Path $run 'late') *> $log
 if($LASTEXITCODE -ne 0){throw "Late-map harness failed: $log"}
 $text=[IO.File]::ReadAllText($log)
 foreach($pattern in @('LOCAL_MAPPING delay_ms=1500 retained=0','branch=provider-convert','AFTER BURST BUF=\[無いかな\].* COMP=-','branch=local-convert','AFTER END BUF=\[無いかな無い\].* COMP=-')) {
  if($text -notmatch $pattern){throw "Late mapping missing $pattern : $log"}; $checks++
 }
 $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
 $maximum=($times | Measure-Object -Maximum).Maximum
 if(-not $times.Count -or $maximum -gt 25000){throw "Late-map callback watchdog: $maximum : $log"}; $checks++
 Write-Output "PASS async SPACE late-map callbacks=$($times.Count) max_us=$maximum checks=$checks log=$log"
 Write-Output "PASS async SPACE cases=4 checks=$checks artifacts=$run"
} finally { foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])} }
