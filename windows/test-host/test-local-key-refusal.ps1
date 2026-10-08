[CmdletBinding(DefaultParameterSetName='Run')]
param([Parameter(Mandatory,ParameterSetName='Run')][string]$Runtime,
      [Parameter(Mandatory,ParameterSetName='Log')][string]$LogPath,
      [Parameter(Mandatory,ParameterSetName='SelfTest')][switch]$SelfTest,
      [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'

# The same validator serves live runs, captured logs, and negative controls.
function Assert-KeyRefusalLog([string]$Text, [string]$Source) {
 $checks=0
 foreach($pattern in @('LOCAL_MAPPING delay_ms=3000 retained=0',
                       'EDIT_ASYNC queued=1','EDIT_ASYNC executed=1',
                       '(?m)^AFTER LOWER_READY BUF=\[無い▽か\*k\] SEL=\d+,\d+ COMP=\d+,\d+\r?$',
                       '(?m)^AFTER LOWER_DENIED BUF=\[無い▽か\*k\] SEL=\d+,\d+ COMP=\d+,\d+\r?$',
                       '(?m)^AFTER UPPER_READY BUF=\[無い書く値▽か\] SEL=\d+,\d+ COMP=\d+,\d+\r?$',
                       '(?m)^AFTER UPPER_DENIED BUF=\[無い書く値▽か\] SEL=\d+,\d+ COMP=\d+,\d+\r?$',
                       '(?m)^AFTER REFUSED BUF=\[無い書く値買う\] SEL=7,7 COMP=-\r?$',
                       '(?m)^AFTER ACCEPTED BUF=\[無い書く値買う書くう値\] SEL=11,11 COMP=-\r?$')) {
  $count=[regex]::Matches($Text,$pattern).Count
  if($count -eq 0 -or ($pattern.StartsWith('(?m)') -and $count -ne 1)){
   throw "Missing or repeated $pattern : $Source"
  };$checks++
 }
 # Prove each injected refusal hit the final okuri key in its own episode.
 foreach($phase in @('LOWER','UPPER')) {
  $episode=[regex]::Match($Text,"(?s)AFTER ${phase}_READY .*?(?=AFTER ${phase}_DENIED )").Value
  if([regex]::Matches($episode,'EDIT_DENIED sync=0 flags=').Count -ne 1 -or
     [regex]::Matches($episode,'LOCAL_EDIT denied=1').Count -ne 1 -or
     $episode -notmatch 'KEYBRANCH vk=55 branch=local-okuri-convert') {
   throw "Refusal missed $phase final okuri key: $Source"
  };$checks++
 }
 if([regex]::Matches($Text,'EDIT_DENIED sync=0 flags=').Count -ne 2 -or
    [regex]::Matches($Text,'LOCAL_EDIT denied=1').Count -ne 2){throw "Both async-capable okuri writes must be refused: $Source"};$checks++
 if($Text -match 'branch=provider-(queue|convert|accept-and-queue)|SETTLE TIMEOUT'){throw "Native ownership lost: $Source"};$checks++
 $times=@([regex]::Matches($Text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
 $maximum=($times | Measure-Object -Maximum).Maximum
 if(-not $times.Count -or $maximum -gt 25000){throw "Callback watchdog exceeded 25000 us: $maximum : $Source"};$checks++
 [pscustomobject]@{Checks=$checks;Callbacks=$times.Count;Maximum=$maximum}
}
function Test-KeyRefusalNegativeControls([string]$Text) {
 $controls=0
 foreach($change in @(@('無い書く値買う','無い書くう値買う'),
                       @('無い書く値買う書くう値','無い書く値買う書く値'),
                       @('無い書く値買う書くう値','無い書く値買う書くうう値'))) {
  $bad=$Text.Replace(('BUF=['+$change[0]+']'),('BUF=['+$change[1]+']'))
  if($bad -ceq $Text){throw 'Negative control did not mutate a checkpoint'}
  $rejected=$false
  try {$null=Assert-KeyRefusalLog $bad 'negative-control'} catch {
   if($_.Exception.Message -notlike 'Missing or repeated *'){throw}
   $rejected=$true
  }
  if(-not $rejected){throw 'Corrupted key output passed the validator'}
  $controls++
 }
 $controls
}
if($SelfTest) {
 # Synthetic logs validate the checker only; they are never harness evidence.
 $sample=@('LOCAL_MAPPING delay_ms=3000 retained=0',
 'EDIT_ASYNC queued=1','EDIT_ASYNC executed=1',
 'AFTER LOWER_READY BUF=[無い▽か*k] SEL=6,6 COMP=2,6',
 'EDIT_DENIED sync=0 flags=6','LOCAL_EDIT denied=1',
 'KEYBRANCH vk=55 branch=local-okuri-convert',
 'AFTER LOWER_DENIED BUF=[無い▽か*k] SEL=6,6 COMP=2,6',
 'AFTER UPPER_READY BUF=[無い書く値▽か] SEL=7,7 COMP=5,7',
 'EDIT_DENIED sync=0 flags=6','LOCAL_EDIT denied=1',
 'KEYBRANCH vk=55 branch=local-okuri-convert',
 'AFTER UPPER_DENIED BUF=[無い書く値▽か] SEL=7,7 COMP=5,7',
 'AFTER REFUSED BUF=[無い書く値買う] SEL=7,7 COMP=-',
 'AFTER ACCEPTED BUF=[無い書く値買う書くう値] SEL=11,11 COMP=-',
 'KEYLAT token=u total_us=1 claimed=1') -join "`n"
 $result=Assert-KeyRefusalLog $sample 'synthetic-self-test'
 $negative=Test-KeyRefusalNegativeControls $sample
 Write-Output "PASS key-refusal checker checks=$($result.Checks) negative_controls=$negative harness_run=0"
 return
}
if($LogPath) {
 $text=[IO.File]::ReadAllText([IO.Path]::GetFullPath($LogPath))
 $result=Assert-KeyRefusalLog $text $LogPath
 $negative=Test-KeyRefusalNegativeControls $text
 Write-Output "PASS local key refusal log checks=$($result.Checks) callbacks=$($result.Callbacks) max_us=$($result.Maximum) negative_controls=$negative log=$LogPath"
 return
}
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
 # Begin before rules map; queue a commit and immediate next reading across
 # an async lock. Drain confirmation/fresh-key sessions before arming denial:
 # DENYWRITE targets the next actual write, not the next queued script key.
 $keys='KEYGAP0 N a i WAIT3500 ASYNCWRITE SPACE ENTER K a K ASYNCFLUSH SETTLE8000:LOWER_READY '
 $keys+='DENYWRITE u SETTLE8000:LOWER_DENIED u SPACE x ENTER A t a i SPACE ENTER K a SETTLE8000:UPPER_READY '
 $keys+='DENYWRITE U SETTLE8000:UPPER_DENIED U ENTER SETTLE8000:REFUSED '
 # Stock DDSKK commits 書く and inserts う for the second accepted u.
 # It leaves direct input, so Enter here would insert an application newline.
 # Queue the next reading immediately instead, exercising fresh-key replay.
 $keys+='K a K u u A t a i SPACE SPACE x ENTER SETTLE8000:ACCEPTED'
 $log=Join-Path $run 'keys.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
  -Script $keys -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
  -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
  -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec `
  -InputRulesFile $rules -DebugLog -ArtifactDirectory $run *> $log
 if($LASTEXITCODE -ne 0){throw "Harness failed: $log"}
 $result=Assert-KeyRefusalLog ([IO.File]::ReadAllText($log)) $log
 $negative=Test-KeyRefusalNegativeControls ([IO.File]::ReadAllText($log))
 Write-Output "PASS local key refusal cases=2 checks=$($result.Checks) callbacks=$($result.Callbacks) max_us=$($result.Maximum) late_rules=1 immediate_commits=1 accepted_repeat=preserved refused_repeat=once negative_controls=$negative log=$log"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
