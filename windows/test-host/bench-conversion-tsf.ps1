[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][string]$Dictionary,
      [string]$BuildDir='build/w', [int]$Iterations=20,
      [int]$ColdLoadSleepSec=45, [ValidateRange(0,1)][int]$LocalConversion=0)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('tsf-conversion-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$copy=Join-Path $run 'SKK-JISYO.L.utf8'
Copy-Item -LiteralPath $Dictionary -Destination $copy
if ($Iterations -lt 20) { throw 'At least 20 iterations required' }
function Machine-Load {
  $timer=[Diagnostics.Stopwatch]::StartNew(); $before=@{}
  Get-Process | ForEach-Object { try {$before[$_.Id]=$_.CPU} catch {} }
  Start-Sleep -Seconds 1
  $rows=@(Get-Process | ForEach-Object { if ($before.ContainsKey($_.Id)) { try {
    [pscustomobject]@{name=$_.ProcessName; pid=$_.Id; cpuMs=1000*($_.CPU-$before[$_.Id])}
  } catch {} } } | Sort-Object cpuMs -Descending | Select-Object -First 8)
  [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o'); intervalMs=$timer.Elapsed.TotalMilliseconds; top=$rows}
}
$loads=[Collections.Generic.List[object]]::new()
for ($i=0;$i -lt 10;$i++) {
  $load=Machine-Load; $loads.Add($load)
  $busy=@($load.top | Where-Object {$_.pid -ne $PID -and $_.cpuMs/$load.intervalMs -gt .3})
  if (-not $busy.Count) {break}
  Write-Output "Quiet check: heavy processes present; retry $($i+1)/10"
  Start-Sleep -Seconds 5
}
$loads | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $run 'load-before.json')
if ($busy.Count) { throw "Machine remains busy; load evidence: $run" }
$names=@('DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_START_COMMAND',
 'DDSKK_HARNESS_DIAGNOSTICS','DDSKK_HOST_DEBUG','DDSKK_PHASE_TRACE','NELISP_IME_ENGINE')
$saved=@{}; foreach ($name in $names) {$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
  $env:DDSKK_DICTIONARY_FILES=$copy; $env:DDSKK_SKKSERV_ENABLE='0'; $env:DDSKK_SKKSERV_START_COMMAND=''
  $env:DDSKK_HARNESS_DIAGNOSTICS='1'; $env:DDSKK_HOST_DEBUG='1'; $env:DDSKK_PHASE_TRACE='1'
  $env:NELISP_IME_ENGINE='ddskk'
  # First episode warms the provider. Keep the instructed lattice warm-up.
  $script='a i SPACE SETTLE30000 ENTER SETTLE30000 ' + ((1..($Iterations+1) | ForEach-Object {
    'K a n a SPACE SETTLE30000 ENTER SETTLE30000'
  }) -join ' ')
  $log=Join-Path $run 'tsf.log'
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script $script -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') `
    -EngineExecutablePath $Runtime -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') `
    -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -ColdLoadSleepSec $ColdLoadSleepSec `
    -TsfHostTimeoutSec 180 -LocalConversion $LocalConversion *> $log
  if ($LASTEXITCODE -ne 0) {Get-Content $log -Tail 20; throw "Harness exit $LASTEXITCODE"}
  $after=Machine-Load
  $after | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $run 'load-after.json')
  $values=@(Get-Content $log | ForEach-Object {
    if ($_ -match '^SPACE-CANDIDATE ms=(\d+) seq=(\d+)') {
      if (($LocalConversion -eq 0 -and [int]$Matches[2] -gt 2) -or
          ($LocalConversion -eq 1 -and $_.Contains('path=local') -and [int]$Matches[2] -gt 1)) {[int]$Matches[1]}
    }
  } | Sort-Object)
  if ($values.Count -lt $Iterations) {throw "Completed TSF conversions $($values.Count)/$Iterations; log=$log"}
  $p50=$values[[int][Math]::Ceiling($values.Count*.5)-1]
  $p90=$values[[int][Math]::Ceiling($values.Count*.9)-1]
  Write-Output "TSF n=$($values.Count) p50=$p50 p90=$p90 max=$($values[-1]) log=$log"
  if (@($after.top | Where-Object {$_.pid -ne $PID -and $_.cpuMs/$after.intervalMs -gt .3}).Count) {
    throw 'Machine became busy; wall-clock gate remains unverified'
  }
  if ($p50 -gt 100 -or $p90 -gt 150) {throw 'FAIL S3.1: p50 >100 ms or p90 >150 ms'}
  if ($LocalConversion -eq 1 -and ($p50 -gt 30 -or $p90 -gt 30)) {throw 'FAIL S2.3: local p50/p90 >30 ms'}
  Write-Output 'PASS S3.1'
} finally {
  foreach ($name in $names) {[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
