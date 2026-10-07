[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('tl1-key-refusal-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$personal=Join-Path $run 'personal.utf8'; $shared=Join-Path $run 'shared.utf8'
[IO.File]::WriteAllText($personal,"ない /無い/内/`nかk /書/掛/`nかu /買/`nあたい /値/`n",$utf8)
[IO.File]::WriteAllText($shared,"ない /無い/亡い/`nかk /書/掛/`nかu /買/`nあたい /値/価/`n",$utf8)
$rules=Join-Path $run 'input-rules.conf'
[IO.File]::WriteAllText($rules,"[symbols-hankaku]`n, = `"、`"`n. = `"。`"`n",$utf8)
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LOCAL_MAP_DELAY_MS')) {
 $saved[$name]=[Environment]::GetEnvironmentVariable($name)
}
try {
 $env:DDSKK_DICTIONARY_FILES=$personal+';'+$shared
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'; $env:NATIVEIME_TEST_LOCAL_MAP_DELAY_MS='3000'
 # Begin the reading before the rules are mapped. Hold async sessions across
 # commits and immediate next keys; each denied final okuri key is retried once.
 $keys='KEYGAP0 N a i WAIT3500 ASYNCWRITE SPACE ENTER K a K DENYWRITE u u SPACE x ENTER A t a i SPACE ENTER K a DENYWRITE U U ENTER ASYNCFLUSH SETTLE8000:REFUSED '
 # This second u is a genuine accepted key. It must remain after committing
 # the first okuri candidate, never be swallowed as a synthetic retry.
 $keys+='K a K u u ENTER A t a i SPACE SPACE x ENTER SETTLE8000:ACCEPTED'
 $log=Join-Path $run 'keys.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
  -Script $keys -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
  -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
  -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec `
  -InputRulesFile $rules -DebugLog -ArtifactDirectory $run *> $log
 if($LASTEXITCODE -ne 0){throw "Harness failed: $log"}
 $text=[IO.File]::ReadAllText($log);$checks=0
 foreach($pattern in @('LOCAL_MAPPING delay_ms=3000 retained=0',
                       'EDIT_ASYNC queued=1','EDIT_ASYNC executed=1',
                       'AFTER REFUSED BUF=\[無い書く値買う\].* COMP=-',
                       'AFTER ACCEPTED BUF=\[無い書く値買う書くう値\].* COMP=-')) {
  if($text -notmatch $pattern){throw "Missing $pattern : $log"};$checks++
 }
 if(@([regex]::Matches($text,'EDIT_DENIED sync=0 flags=')).Count -ne 2 -or
    @([regex]::Matches($text,'LOCAL_EDIT denied=1')).Count -ne 2){throw "Both async-capable okuri writes must be refused: $log"};$checks++
 if($text -match 'branch=provider-(queue|convert|accept-and-queue)|SETTLE TIMEOUT'){throw "Native ownership lost: $log"};$checks++
 $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
 $maximum=($times | Measure-Object -Maximum).Maximum
 if(-not $times.Count -or $maximum -gt 25000){throw "Callback watchdog exceeded 25000 us: $maximum : $log"};$checks++
 Write-Output "PASS local key refusal cases=2 checks=$checks callbacks=$($times.Count) max_us=$maximum late_rules=1 immediate_commits=1 accepted_repeat=preserved refused_repeat=once log=$log"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
