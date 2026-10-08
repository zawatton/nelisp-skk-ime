[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w',
      [string]$InputRulesFile='build/live-input-rules.conf',
      [int]$ColdLoadSleepSec=45,
      # Replay existing host logs without launching hosts or touching registry.
      [string]$LogDirectory='',
      [ValidateSet(0,1)][int[]]$Providers=@(1,0),
      [ValidateSet('period','comma','okuri','preedit','next','previous','fast','async','letter','reading','letter-fast','letter-async','typeahead','period-denied','letter-denied','okuri-denied')]
      [string[]]$Cases=@('period','comma','okuri','preedit','next','previous','fast','async'))
$ErrorActionPreference='Stop'
function Read-PunctSnapshot([string]$Text,[string]$Label) {
 $pattern='^AFTER '+[regex]::Escape($Label)+' BUF=\[(.*)\] SEL=(\d+),(\d+) COMP=(-|\d+,\d+)\s*$'
 $lines=@($Text -split "`n" | Where-Object { $_ -match $pattern })
 if (!$lines.Count -or $lines[-1] -notmatch $pattern) { throw "Missing snapshot: $Label" }
 $buffer=$Matches[1]; $composition=$Matches[4]
 $hex=($buffer.ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ }) -join ''
 return [pscustomobject]@{Hex=$hex; Composition=$composition; Length=$buffer.Length}
}
function Assert-PunctComposition($Snapshot,[bool]$Composing,[string]$Name,[int]$Start=0) {
 # Lifecycle events after FINAL describe teardown. Only the RESULT snapshot
 # observes the composition at the same moment as the asserted document text.
 $expected=if ($Composing) { "$Start,$($Snapshot.Length)" } else { '-' }
 if ($Snapshot.Composition -ne $expected) {
  throw "Composition mismatch $Name expected=$expected actual=$($Snapshot.Composition)"
 }
}
function Assert-PunctImm([string]$Text,[string]$Name,[string]$Word,[string]$Suffix,[int]$Count,[string]$Last='') {
 $lines=@($Text -split "`n" | Where-Object { $_ -match '^IMM AFTER RESULT COUNT=(\d+) LAST=(\S+) TEXT=(\S+)\s*$' })
 if (!$lines.Count -or $lines[-1] -notmatch '^IMM AFTER RESULT COUNT=(\d+) LAST=(\S+) TEXT=(\S+)\s*$') { throw "Missing IMM RESULT: $Name" }
 $actualCount=[int]$Matches[1]; $last=$Matches[2]; $actualText=$Matches[3]
 $expectedText=if ($Count) { $Word+$Suffix } else { '-' }
 $expectedLast=if ($Last) { $Last } elseif (!$Count) { '-' } elseif ($Suffix) { $Suffix } else { $Word }
 if ($actualCount -ne $Count -or $last -ne $expectedLast -or $actualText -ne $expectedText) {
  throw "IMM mismatch $Name expected=$Count/$expectedLast/$expectedText actual=$actualCount/$last/$actualText"
 }
 if ($Count) {
  # APPCLEAR resets result counts after warm-up. Scope the episode to the
  # candidate event, rather than matching earlier warm-up count=2 events.
  # Match objects also avoid caller/pipeline changes to PowerShell's $Matches.
  $candidates=[regex]::Matches($Text,('(?m)^IMMRESULT count=1 lock=(\d+) range=\d+,\d+ hex='+[regex]::Escape($Word)+'[^\S\r\n]*\r?$'))
  if (!$candidates.Count) { throw "Missing separate candidate result: $Name" }
  $candidate=$candidates[$candidates.Count-1]
  $episode=$Text.Substring($candidate.Index)
  $previousLock=[long]$candidate.Groups[1].Value
  for ($index=2; $index -le $Count; $index++) {
   $result=[regex]::Match($episode,('(?m)^IMMRESULT count='+$index+' lock=(\d+) range=\d+,\d+ hex=\S+[^\S\r\n]*\r?$'))
   if (!$result.Success -or [long]$result.Groups[1].Value -le $previousLock) {
    throw "Candidate and following result share a lock or run out of order: $Name"
   }
   $previousLock=[long]$result.Groups[1].Value
  }
 }
}
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$rules=[IO.Path]::GetFullPath((Join-Path $root $InputRulesFile))
$run=if ($LogDirectory) { [IO.Path]::GetFullPath($LogDirectory) } else { Join-Path $build ('punct-tsf-'+[guid]::NewGuid().ToString('N')) }
if (!$LogDirectory) { New-Item -ItemType Directory $run | Out-Null }
$saved=$env:DDSKK_HARNESS_DIAGNOSTICS
$checks=0; $completedCases=0
try {
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 foreach ($local in $Providers) {
  foreach ($case in $Cases) {
   $keys='K a n a SPACE SETTLE30000:SELECTED'; $punct='PERIOD'; $suffix='3002'
   switch ($case) {
    comma { $punct='COMMA'; $suffix='3001' }
    okuri { $keys='K i e R u SETTLE30000:SELECTED' }
    preedit { $keys='K a n a SETTLE30000:SELECTED' }
    next { $keys+=' SPACE SETTLE30000:SELECTED' }
    previous { $keys+=' SPACE SETTLE30000:NEXT LEFT SETTLE30000:SELECTED' }
    fast { $keys='K a n a SPACE' }
    async { $keys+=' ASYNCWRITE' }
    letter { $punct='k'; $suffix='006b' }
    reading { $punct='K'; $suffix='25bd006b' }
    letter-fast { $keys='KEYGAP0 K a n a SPACE'; $punct='k'; $suffix='006b' }
    letter-async { $keys+=' ASYNCWRITE'; $punct='k'; $suffix='006b' }
    typeahead { $keys='KEYGAP0 K a n a SPACE'; $punct='PERIOD k a'; $suffix='3002304b' }
    period-denied { $punct='DENYWRITE PERIOD' }
    letter-denied { $punct='DENYWRITE k'; $suffix='006b' }
    okuri-denied { $keys='K i e R u SETTLE30000:SELECTED'; $punct='DENYWRITE PERIOD' }
   }
   $tail=if ($case -in @('async','letter-async')) { 'ASYNCFLUSH SETTLE30000:RESULT' } else { 'SETTLE30000:RESULT' }
   $script="a i SPACE WAIT3000 ENTER SETTLE30000:WARM APPCLEAR $keys $punct $tail"
   $name="$local-$case"; $log=Join-Path $run ($name+'.log')
   if (!$LogDirectory) {
   & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
     -Script $script -LocalConversion $local -InputRulesFile $rules `
     -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') `
     -EngineExecutablePath $Runtime -RepositoryPath $root `
     -DllPath (Join-Path $build 'Release/ddskk-ime.dll') `
     -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
     -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') `
     -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run $name) *> $log
   if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 15; throw "Harness failed: $name" }
   }
   $text=[IO.File]::ReadAllText($log)
   $word=switch ($case) { {$_ -in @('okuri','okuri-denied')} {'6d883048308b'} next {'54c9'} default {'4eee540d'} }
   $expected=$word+$suffix
   if ($case -notin @('fast','letter-fast','typeahead')) {
    $selected=(Read-PunctSnapshot $text SELECTED).Hex
    if ($case -eq 'preedit') {
     if ($selected -ne '25bd304b306a') { throw "Unexpected preedit $selected" }
     $expected='25bc'+$expected
    } else {
     if ($selected -ne '25bc'+$word) { throw "Unexpected selected candidate $name/$selected" }
    }
   }
   $snapshot=Read-PunctSnapshot $text RESULT
   $actual=$snapshot.Hex
   if ($actual -ne $expected) { throw "Mismatch $name expected=$expected actual=$actual log=$log" }
   $checks++
   $newReading=$case -in @('letter','reading','letter-fast','letter-async','letter-denied')
   Assert-PunctComposition $snapshot ($case -eq 'preedit' -or $newReading) $name $(if($newReading) {2} else {0})
   $checks++
   if ($case -eq 'preedit') { Assert-PunctImm $text $name '' '' 0 }
   elseif ($newReading) { Assert-PunctImm $text $name $word '' 1 }
   elseif ($case -eq 'typeahead') {
    # Three ended episodes: candidate, punctuation, then completed kana.
    Assert-PunctImm $text $name $word $suffix 3 '304b'
   }
   else { Assert-PunctImm $text $name $word $suffix 2 }
   $checks++
   if ($case.EndsWith('-denied')) {
    if (@([regex]::Matches($text,'EDIT_DENIED sync=\d flags=')).Count -ne 1) { throw "Write refusal was not exercised exactly once: $name" }
    $checks++
   }
   if ($local -eq 1 -and $case -ne 'preedit' -and $text -notmatch 'branch=local-(okuri-)?convert') { throw "Missing local conversion: $name" }
   if ($local -eq 0 -and $text -match 'branch=local-(okuri-)?convert') { throw "Unexpected local conversion: $name" }
   $checks++; $completedCases++
   Write-Output "PASS punctuation case=$name log=$log"
  }
 }
 Write-Output "PASS punctuation cases=$completedCases checks=$checks artifacts=$run"
} finally { $env:DDSKK_HARNESS_DIAGNOSTICS=$saved }
