[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-cleanup-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$log=Join-Path $run 'harness.log'
$job=Start-Job -ScriptBlock {
 param($root,$build,$run,$log,$runtime,$cold)
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'windows/test-host/run-harness.ps1') -Script 'a i SPACE WAIT3000 ENTER WAIT15000' -LocalConversion 1 -ColdLoadSleepSec $cold -ArtifactDirectory $run -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $runtime -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') *> $log
 if($LASTEXITCODE -ne 0){throw "Cleanup harness failed: $log"}
} -ArgumentList $root,$build,$run,$log,$Runtime,$ColdLoadSleepSec
$live='';$checks=0
try {
 $deadline=(Get-Date).AddSeconds($ColdLoadSleepSec+60)
 do {
  $manifests=@(Get-ChildItem -LiteralPath $run -Filter current -Recurse -File)
  if($manifests.Count){break}
  if($job.State -eq 'Failed' -or (Get-Date) -gt $deadline){throw "Missing manifest: $log"}
  Start-Sleep -Milliseconds 50
 } while($true)
 $dir=$manifests[0].DirectoryName
 $live=Join-Path $dir ('pending-'+$PID+'-live.queue')
 [IO.File]::WriteAllText($live,'');[IO.File]::WriteAllText($live+'.lock','')
 $dead=Join-Path $dir 'pending-4294967295-replay.queue'
 # A dead client learns a real ordinary reading. Duplicate spools must replay
 # idempotently, and deletion must follow the durable checkpoint ACK.
 $record='11111111111111111111111111111111.1 00304b00306a 0054c9 0 -'+"`n"
 [IO.File]::WriteAllText($dead,$record);[IO.File]::WriteAllText($dead+'.lock','')
 $duplicate=Join-Path $dir 'pending-4294967295-duplicate.queue'
 [IO.File]::WriteAllText($duplicate,$record);[IO.File]::WriteAllText($duplicate+'.lock','')
 $empty=Join-Path $dir 'pending-4294967295-empty.queue'
 [IO.File]::WriteAllText($empty,'');[IO.File]::WriteAllText($empty+'.lock','')
 $orphan=Join-Path $dir 'pending-4294967295-orphan.queue.lock'
 [IO.File]::WriteAllText($orphan,'')
 $abandoned=Join-Path $dir 'overlay-abandoned.index'
 [IO.File]::WriteAllText($abandoned,'incomplete');[IO.File]::WriteAllText($abandoned+'.manifest','incomplete')
 $deadline=(Get-Date).AddSeconds(15)
 do {
  $remaining=@($dead,$dead+'.lock',$duplicate,$duplicate+'.lock',$empty,$empty+'.lock',$orphan,$abandoned,$abandoned+'.manifest' | Where-Object {Test-Path -LiteralPath $_})
  if(-not $remaining.Count){break}
  Start-Sleep -Milliseconds 50
 } while((Get-Date) -lt $deadline)
 if($remaining.Count){throw "Dead/orphan files retained: $remaining"};$checks++
 if(-not (Test-Path $live) -or -not (Test-Path ($live+'.lock'))){throw 'Live but unlocked spool was claimed'};$checks++
 $deadline=(Get-Date).AddSeconds(15)
 do {
  $name=[IO.File]::ReadAllText($manifests[0].FullName)
  $bytes=[IO.File]::ReadAllBytes((Join-Path $dir $name))
  if([BitConverter]::ToUInt64($bytes,56) -ge 1){break}
  Start-Sleep -Milliseconds 50
 } while((Get-Date) -lt $deadline)
 if([BitConverter]::ToUInt64($bytes,56) -ne 1){throw 'Duplicate recovery did not publish exactly one learning sequence'};$checks++
 if(@(Get-ChildItem -LiteralPath $dir -Filter 'generation-*.index').Count -ne 1){throw 'Recovery rebuilt base'};$checks++
 [IO.File]::WriteAllText((Join-Path $run 'recovery.txt'),"replayed=1 duplicate_sequence=1 live_preserved=1 deleted=9")
 Wait-Job $job -Timeout ($ColdLoadSleepSec+90) | Out-Null
 Receive-Job $job -ErrorAction Stop
 if($job.State -ne 'Completed'){throw "Cleanup harness incomplete: $log"}
 Write-Output "PASS local cleanup checks=$checks replayed=1 duplicate_sequence=1 live_preserved=1 deleted=9 artifacts=$run"
} finally {
 if($live){Remove-Item -LiteralPath $live,($live+'.lock') -Force -ErrorAction SilentlyContinue}
 if($job.State -eq 'Running'){Wait-Job $job -Timeout 60 | Out-Null}
 if($job.State -eq 'Running'){throw "Harness cleanup still running: $log"}
 Remove-Job $job
}
