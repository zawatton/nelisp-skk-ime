# Focused host replacement/settings regression; one owned stack, no bundle suite.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,[switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$run=Join-Path $root ($BuildDir+'/post-swap-'+[guid]::NewGuid().ToString('N'))
if (-not [IO.Path]::GetFullPath($run).StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)) {throw 'Private build directory required'}
foreach($file in @($Runtime,(Join-Path $bin 'ddskk-ime.dll'),(Join-Path $bin 'ddskk-ime-core.dll'),
    (Join-Path $bin 'ddskk-engine-host.exe'),(Join-Path $bin 'tsf-host.exe'))) {
  if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing file: $file"}
}
if($ValidateParametersOnly){Write-Output 'PASS post-swap parameters stacks=0 cold_load=45 watchdog_ms=20';return}
[void](New-Item -ItemType Directory $run)
$names=@('NATIVEIME_TEST_CALLBACK_IO_PROBE','NATIVEIME_TEST_CALLBACK_WAIT_CONTROL','DDSKK_HARNESS_DIAGNOSTICS',
  'DDSKK_HOST_POLICY_SOURCES','DDSKK_HOST_POLICY_CACHE','DDSKK_HOST_POLICY_RESTART','DDSKK_HOST_POLICY_PUBLICATION','DDSKK_HOST_POLICY_LEARNING')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
  $env:NATIVEIME_TEST_CALLBACK_IO_PROBE='1';$env:NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0'
  $env:DDSKK_HARNESS_DIAGNOSTICS='1'
  foreach($name in $names | Where-Object {$_ -like 'DDSKK_HOST_POLICY_*'}){[Environment]::SetEnvironmentVariable($name,'0')}
  # Kill only the harness-attributed child and host. Both old processes are
  # gone before the settings worker starts their replacement on this pipe.
  # K observes the same-id refresh; lowercase a observes the actual switch.
  $tokens='a i SPACE WAIT3000 ENTER SETTLE30000:WARM S i - k e n n s y a r u q SETTLE30000:KATAKANA DEBUGREFRESH WAIT700 K a n a SPACE WAIT3000 ENTER SETTLE30000:BEFORE WAITACK30000:1 KILLCHILD KILLHOST SETTINGSREFRESH WAIT700 SETTLE30000:UI PROVIDERREFRESH WAIT700 K a n a SPACE ENTER SETTLE30000:SWAP WAITACK30000:2 ENGINE:lattice WAIT700 a i WAIT45000 SPACE WAIT3000 ENTER SETTLE30000:LATTICE ENGINE:ddskk WAIT700 K a n a SPACE ENTER SETTLE30000:FINAL'
  $log=Join-Path $run 'gate.log'
  & python -B (Join-Path $PSScriptRoot 'host-test-process-guard.py') run --root $root --cleanup -- `
    pwsh -NoProfile -File (Join-Path $PSScriptRoot 'run-harness.ps1') -Script $tokens `
    -EngineHostPath (Join-Path $bin 'ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
    -RepositoryPath $root -DllPath (Join-Path $bin 'ddskk-ime.dll') -CoreDllPath (Join-Path $bin 'ddskk-ime-core.dll') `
    -TsfHostExe (Join-Path $bin 'tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec `
    -SkipEngineWarmup -PipeWaitTimeoutSec 10 -TsfHostTimeoutSec 90 -ArtifactDirectory (Join-Path $run 'harness') *> $log
  if($LASTEXITCODE -ne 0){Get-Content $log -Tail 15;throw "Post-swap harness failed: $log"}
  $text=[IO.File]::ReadAllText($log)
  $start=$text.IndexOf('AFTER WARM ');if($start -lt 0){throw 'Missing warm boundary'}
  $warm=$text.Substring($start)
  $boundary=$warm.IndexOf('AFTER ENGINE:lattice ')
  if($boundary -lt 0){throw 'Missing actual-engine-switch boundary'}
  $localLog=Join-Path $run 'local-callbacks.log'
  [IO.File]::WriteAllText($localLog,$text.Substring(0,$start)+$warm.Substring(0,$boundary),[Text.UTF8Encoding]::new($false))
  # The unchanged S4 checker covers native traffic through the replacement.
  & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-host-policy-callbacks.ps1') -Runtime $Runtime -CheckLogOnly $localLog
  if($LASTEXITCODE -ne 0){throw 'Existing S4 callback checker rejected post-swap traffic'}
  $rows=@([regex]::Matches($warm,'CALLBACK_IO hooks=(\d+) mask=(\d+) pipe_io=(\d+) blocking_waits=(\d+)'))
  if($rows.Count -lt 20){throw 'Missing callback probes'}
  foreach($row in $rows){
    if(([int]$row.Groups[2].Value -band 271) -ne 271){throw 'Incomplete callback imports'}
    if([int]$row.Groups[3].Value -or [int]$row.Groups[4].Value){throw 'Post-swap callback IPC/wait'}
  }
  $times=@([regex]::Matches($warm,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
  if(-not $times.Count -or ($times | Measure-Object -Maximum).Maximum -gt 20000){throw 'Callback 20 ms watchdog failed'}
  foreach($engine in @('lattice','ddskk')){if($warm -notmatch "PROVIDER_SETTINGS engine=$engine applied=1"){throw "Engine switch missing: $engine"}}
  if($warm -notmatch 'TEST_KILL token=KILLHOST .*success=1' -or $warm -match 'SETTLE TIMEOUT'){throw 'Host replacement did not complete'}
  if($warm -notmatch 'SETTINGS_REFRESH scale=90' -or $warm -notmatch 'PROVIDER_REFRESH repository_changed=1'){throw 'Settings refresh evidence missing'}
  $irrelevant=[regex]::Match($warm,'(?s)SETTINGS_REFRESH scale=90.*?AFTER UI ')
  if(-not $irrelevant.Success -or $irrelevant.Value -match 'PROVIDER_SETTINGS'){throw 'Irrelevant settings reconnected'}
  if($warm -notmatch 'AFTER KATAKANA BUF=\[あいシーケンシャル\].*COMP=-' -or $warm -notmatch 'branch=q-katakana-local'){throw 'Native q did not commit the complete reading'}
  if($warm -notmatch 'SETTINGS_REFRESH debug=1'){throw 'DllDebug-style refresh missing'}
  $debugLogs=@(Get-ChildItem -LiteralPath (Join-Path $run 'harness') -Filter 'dll-debug.log' -Recurse)
  if(-not $debugLogs.Count){throw 'DllDebug change was not picked up'}
  $debugText=($debugLogs | ForEach-Object {[IO.File]::ReadAllText($_.FullName)}) -join "`n"
  $firstDirect=[regex]::Match($debugText,'OnKeyDown vk=4B branch=(\S+)')
  if(-not $firstDirect.Success -or $firstDirect.Groups[1].Value -in @('provider-queue','confirmation-queue')){throw 'Next idle key stayed deferred after debug refresh'}
  # Exact document detects missing/replayed first keys on both settings boundaries.
  if($warm -notmatch 'AFTER SWAP BUF=\[あいシーケンシャル仮名仮名\].*COMP=-'){throw 'Immediate post-swap conversion was lost'}
  # The katakana reading types a legitimate lowercase k ("kenn"), so match each
  # scripted uppercase K token to an intact Shift+K delivery instead.
  $scriptedK=[regex]::Matches($warm,'SCRIPTKEY token=K ').Count
  if($scriptedK -ne 3 -or
      [regex]::Matches($warm,'KEYINPUT vk=4B scalar=0000004B source=test shift=1').Count -ne $scriptedK){throw 'Scripted uppercase K was not delivered intact'}
  # The lattice engine's first candidate for あい is 愛 (observed, deterministic).
  if($warm -notmatch 'AFTER FINAL BUF=\[あいシーケンシャル仮名仮名愛仮名\].*COMP=-'){throw 'Post-swap exact document failed'}
  if($text -notmatch 'GUARD .*"leftovers": \[\]'){throw 'Owned process cleanup proof missing'}
  Write-Output "PASS post-swap callbacks probes=$($rows.Count) pipe_io=0 blocking_waits=0 engine_switches=2 exact_document=1 log=$log"
} finally {foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
