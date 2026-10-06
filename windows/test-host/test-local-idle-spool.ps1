[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-idle-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$pidFile=Join-Path $run 'tsf.pid'
$log=Join-Path $run 'harness.log'
$job=Start-Job -ScriptBlock {
 param($root,$build,$run,$pidFile,$log,$runtime,$cold)
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'windows/test-host/run-harness.ps1') `
  -Script 'a i SPACE WAIT3000 ENTER WAIT15000' -LocalConversion 1 `
  -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $runtime `
  -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') `
  -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') `
  -ColdLoadSleepSec $cold -ArtifactDirectory $run -InlinePidFile $pidFile *> $log
 if($LASTEXITCODE -ne 0){throw "Harness exit=$LASTEXITCODE log=$log"}
} -ArgumentList $root,$build,$run,$pidFile,$log,$Runtime,$ColdLoadSleepSec
try {
 $deadline=(Get-Date).AddSeconds($ColdLoadSleepSec+90)
 while(-not (Test-Path $pidFile)) {
  if($job.State -eq 'Failed' -or (Get-Date) -gt $deadline){throw "Harness startup failed: $log"}
  Start-Sleep -Milliseconds 100
 }
 # The scripted conversion warms the first lattice lookup. Observe only the
 # subsequent WAIT interval, with no keys, learning or handoff in the sample.
 Start-Sleep -Seconds 8
 $tsfPid=[int]([IO.File]::ReadAllText($pidFile))
 if(-not (Get-Process -Id $tsfPid -ErrorAction SilentlyContinue)){throw 'TSF exited before idle observation'}
 if(@(Get-ChildItem -LiteralPath $run -Filter current -Recurse -File).Count -ne 1){throw 'Missing private local publication'}
 $last=@{}; $writes=0
 foreach($file in @(Get-ChildItem -LiteralPath $run -Filter 'pending-*.queue' -Recurse -File)){$last[$file.FullName]=$file.LastWriteTimeUtc.Ticks}
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while($watch.Elapsed.TotalSeconds -lt 5) {
  foreach($file in @(Get-ChildItem -LiteralPath $run -Filter 'pending-*.queue' -Recurse -File)) {
   $stamp=$file.LastWriteTimeUtc.Ticks
   if(-not $last.ContainsKey($file.FullName) -or $last[$file.FullName] -ne $stamp){$writes++}
   $last[$file.FullName]=$stamp
  }
  Start-Sleep -Milliseconds 5
 }
 $watch.Stop()
 if(-not (Get-Process -Id $tsfPid -ErrorAction SilentlyContinue)){throw 'TSF exited during idle observation'}
 Write-Output ('IDLE spool_publications={0} seconds={1:f3} writes_per_sec={2:f3} files={3} artifacts={4}' -f $writes,$watch.Elapsed.TotalSeconds,($writes/$watch.Elapsed.TotalSeconds),$last.Count,$run)
 Wait-Job $job -Timeout 60 | Out-Null
 if($job.State -ne 'Completed'){Receive-Job $job; throw "Harness did not complete: $log"}
 Receive-Job $job
 if($writes -ne 0){throw "Idle spool write regression: $writes publications"}
 Write-Output 'PASS local idle spool writes=0 checks=4'
} finally {
 # Let run-harness execute its own private host/runtime cleanup before removing
 # the job; never terminate unrelated processes or leave its children behind.
 if($job.State -eq 'Running'){Wait-Job $job -Timeout 60 | Out-Null}
 if($job.State -eq 'Running'){throw "Harness cleanup still running: $log"}
 Remove-Job $job
}
