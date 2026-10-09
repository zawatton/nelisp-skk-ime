[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45,[switch]$NegativeControl)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$run=Join-Path $root ($BuildDir+'/s4-callback-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('NATIVEIME_TEST_CALLBACK_IO_PROBE','NATIVEIME_TEST_CALLBACK_WAIT_CONTROL',
  'DDSKK_HARNESS_DIAGNOSTICS','DDSKK_HOST_POLICY_TEST_PAUSE_KIND')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
  $env:NATIVEIME_TEST_CALLBACK_IO_PROBE='1'
  $env:NATIVEIME_TEST_CALLBACK_WAIT_CONTROL=$(if($NegativeControl){'1'}else{'0'})
  $env:DDSKK_HARNESS_DIAGNOSTICS='1'
  $env:DDSKK_HOST_POLICY_TEST_PAUSE_KIND='9'
  $log=Join-Path $run 'callbacks.log'
  $tokens='a i SPACE WAIT3000 ENTER SETTLE30000:WARM K a n a SPACE SPACE x CTRLG SPACE ENTER SETTLE30000:COMMIT K a n a SPACE ENTER SETTLE30000:AHEAD'
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-harness.ps1') -Script $tokens `
    -EngineHostPath (Join-Path $bin 'ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
    -RepositoryPath $root -DllPath (Join-Path $bin 'ddskk-ime.dll') `
    -CoreDllPath (Join-Path $bin 'ddskk-ime-core.dll') -TsfHostExe (Join-Path $bin 'tsf-host.exe') `
    -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run 'harness') *> $log
  if($LASTEXITCODE -ne 0){Get-Content $log -Tail 15;throw "Callback harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  $start=$text.IndexOf('AFTER WARM ')
  if($start -lt 0){throw "Missing warm callback fixture: $log"}
  $warm=$text.Substring($start)
  $rows=@([regex]::Matches($warm,'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)'))
  if($rows.Count -lt 10){throw "Missing callback probes: $log"}
  $io=0;$waits=0
  foreach($row in $rows) {
    # CreateFile/ReadFile/WriteFile/WaitForSingleObject/GetOverlappedResult:
    # all EngineClient transfer imports must actually be covered.
    if(([int]$row.Groups[2].Value -band 271) -ne 271){throw "Incomplete callback imports: $log"}
    $io += [int]$row.Groups[3].Value;$waits += [int]$row.Groups[4].Value
  }
  if($io -or $waits){throw "FAIL S4 callback pipe_io=$io blocking_waits=$waits log=$log"}
  $times=@([regex]::Matches($warm,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
  if(-not $times.Count -or ($times | Measure-Object -Maximum).Maximum -gt 20000){throw "S4 callback 20 ms watchdog failed: $log"}
  if($warm -notmatch 'branch=local-convert' -or $warm -match 'branch=provider-(queue|accept-and-queue|convert)') {
    throw "S4 fixture did not remain local: $log"
  }
  if($warm -notmatch 'LOCAL_ACK ' -or $warm -match 'SETTLE TIMEOUT'){throw "S4 local learning did not settle: $log"}
  Write-Output "PASS S4 callbacks probes=$($rows.Count) pipe_io=0 blocking_waits=0 callback_max_us=$(($times | Measure-Object -Maximum).Maximum) log=$log"
} finally {
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
