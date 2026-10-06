[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [Parameter(Mandatory)][string]$Dictionary,
      [string]$BuildDir='build/w', [int]$Iterations=20, [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
if($Iterations -lt 20){throw 'At least 20 paired iterations required'}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('okuri-paired-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
function LoadSample {
 $before=@{}; Get-Process | ForEach-Object {try{$before[$_.Id]=$_.CPU}catch{}}
 $timer=[Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Seconds 1
 $rows=@(Get-Process | ForEach-Object {if($before.ContainsKey($_.Id)){try{
  [pscustomobject]@{name=$_.ProcessName;pid=$_.Id;fraction=($_.CPU-$before[$_.Id])/$timer.Elapsed.TotalSeconds}
 }catch{}}} | Sort-Object fraction -Descending | Select-Object -First 8)
 $rows
}
try {
 $env:DDSKK_DICTIONARY_FILES=[IO.Path]::GetFullPath($Dictionary); $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 $busy=$false
 foreach($local in @(0,1)) {
  $load=@(LoadSample); $load|ConvertTo-Json|Set-Content (Join-Path $run "load-before-$local.json")
  if(@($load|Where-Object{$_.pid -ne $PID -and $_.fraction -gt .3}).Count){$busy=$true}
  $tokens='CTX2 a i SPACE WAIT3000 ENTER CTX1 '+((1..($Iterations+1)|ForEach-Object{'K a K u SETTLE8000 ENTER SETTLE8000'}) -join ' ')
  $log=Join-Path $run "path-$local.log"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
   -Script $tokens -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
   -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
   -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion $local -ColdLoadSleepSec $ColdLoadSleepSec `
   -TsfHostTimeoutSec 180 -ArtifactDirectory (Join-Path $run "path-$local") *> $log
  if($LASTEXITCODE -ne 0){throw "Latency harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  $path=if($local){'local'}else{'engine'}
  $rows=@([regex]::Matches($text,"OKURI-CANDIDATE us=(\d+) seq=(\d+) path=$path") | Where-Object {[int]$_.Groups[2].Value -gt 1} | ForEach-Object {[int]$_.Groups[1].Value} | Sort-Object)
  if($rows.Count -ne $Iterations){throw "Missing paired samples: path=$path n=$($rows.Count) log=$log"}
  $p50=$rows[[int][Math]::Ceiling($rows.Count*.5)-1];$p90=$rows[[int][Math]::Ceiling($rows.Count*.9)-1]
  $load=@(LoadSample);$load|ConvertTo-Json|Set-Content (Join-Path $run "load-after-$local.json")
  if(@($load|Where-Object{$_.pid -ne $PID -and $_.fraction -gt .3}).Count){$busy=$true}
  Write-Output "OKURI path=$path n=$($rows.Count) p50_us=$p50 p90_us=$p90 max_us=$($rows[-1]) log=$log"
  if($local -and ($p50 -gt 30000 -or $p90 -gt 30000)){throw 'Local p50/p90 exceeds 30000 us'}
 }
 if($busy){throw 'Machine busy; paired samples collected under load, quiet-machine latency unverified'}
 Write-Output 'PASS paired okuri latency; identical complete-kana script, warm-up excluded, same machine'
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
