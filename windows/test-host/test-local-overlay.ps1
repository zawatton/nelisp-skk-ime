[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45, [int]$Words=3, [switch]$Burst)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-overlay-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$source=Join-Path $run 'synthetic-large.utf8'
$writer=New-Object IO.StreamWriter($source,$false,(New-Object Text.UTF8Encoding($false)))
try {
 $writer.WriteLine('かな /仮名/哉/'); $writer.WriteLine('かんじ /漢字/幹事/'); $writer.WriteLine('あたい /値/価/'); $writer.WriteLine('あい /愛/藍/')
 for($i=0;$i -lt 150000;$i++) { $writer.WriteLine(('synthetic{0:d6} /候補候補候補候補候補候補候補候補/' -f $i)) }
} finally { $writer.Dispose() }
$log=Join-Path $run 'harness.log'
$job=Start-Job -ScriptBlock {
 param($root,$build,$run,$source,$log,$runtime,$cold,$words,$burst)
 $env:DDSKK_DICTIONARY_FILES=$source; $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 if($burst){$env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS='5000'}
 $keys=@('K a n a','K a n j i','A t a i')
 $tokens='a i SPACE WAIT3000 ENTER WAIT2000 '
 for($i=0;$i -lt $words;$i++) {
  $tokens+=$keys[$i%3]+$(if($burst){' SPACE SPACE ENTER '}else{' SPACE SETTLE30000 SPACE SETTLE30000 ENTER SETTLE30000 WAIT1500 '})
 }
 $tokens+=$(if($burst){'WAIT30000'}else{'WAIT2500'})
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'windows/test-host/run-harness.ps1') -Script $tokens -LocalConversion 1 -ColdLoadSleepSec $cold -ArtifactDirectory $run -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $runtime -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') *> $log
 if($LASTEXITCODE -ne 0) { throw "Harness failed: $log" }
} -ArgumentList $root,$build,$run,$source,$log,$Runtime,$ColdLoadSleepSec,$Words,$Burst.IsPresent
$seen=@{}
try {
 while($job.State -eq 'Running' -or $job.State -eq 'NotStarted') {
  foreach($file in @(Get-ChildItem -LiteralPath $run -Filter '*.index' -Recurse -File)) { $seen[$file.FullName]=$file.Length }
  Start-Sleep -Milliseconds 25
 }
 Receive-Job $job -ErrorAction Stop
 if($job.State -ne 'Completed') { throw "Harness job failed: $log" }
 $text=[IO.File]::ReadAllText($log)
 $acks=[regex]::Matches($text,'LOCAL_ACK ').Count
 $bases=@($seen.Keys | Where-Object {[IO.Path]::GetFileName($_).StartsWith('generation-')} | Sort-Object)
 $overlays=@($seen.Keys | Where-Object {[IO.Path]::GetFileName($_).StartsWith('overlay-')})
 $baseBytes=0L; foreach($name in $bases) {$baseBytes+=$seen[$name]}
 $overlayBytes=0L; foreach($name in $overlays) {$overlayBytes+=$seen[$name]}
 $learningBytes=$baseBytes+$overlayBytes
 if($bases.Count) {$learningBytes-=$seen[$bases[0]]}
 Write-Output "PUBLICATION words=$Words acks=$acks bases=$($bases.Count) base_bytes=$baseBytes overlays=$($overlays.Count) overlay_bytes=$overlayBytes bytes_per_word=$([Math]::Round($learningBytes/$Words,2)) artifacts=$run"
 if($acks -lt $Words) {throw "Learning ACKs missing: $acks"}
 if($bases.Count -ne 1) {throw "Learning republished base: $($bases.Count) generations"}
 if($overlays.Count -lt 2 -or $overlays.Count -gt $acks+1) {throw 'Overlay publication count'}
 foreach($name in $overlays) {if($seen[$name] -gt 65536) {throw 'Overlay size exceeds small fixture limit'}}
 if($Burst -and $text -notmatch 'LOCAL_PUBLICATION stalled_ms=5000'){throw 'Burst publication stall not exercised'}
 if($Burst -and $overlays.Count -ge $Words){throw 'Burst did not coalesce overlay publications'}
 Write-Output "PASS local overlay publication checks=$(if($Burst){6}else{4}) burst=$($Burst.IsPresent)"
} finally {
 if($job.State -eq 'Running') {Wait-Job $job -Timeout 60 | Out-Null}
 if($job.State -eq 'Running') {throw "Harness cleanup still running: $log"}
 Remove-Job $job
}
