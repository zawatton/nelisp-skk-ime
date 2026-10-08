[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w',
      [string]$InputRulesFile='build/live-input-rules.conf',
      [int]$ColdLoadSleepSec=45,
      # Replay existing host logs without launching hosts or touching registry.
      [string]$LogDirectory='',
      [ValidateSet(0,1)][int[]]$Providers=@(1,0),
      [ValidateSet('period','comma','okuri','preedit','next','previous','fast','async')]
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
function Assert-PunctComposition($Snapshot,[bool]$Composing,[string]$Name) {
 # Lifecycle events after FINAL describe teardown. Only the RESULT snapshot
 # observes the composition at the same moment as the asserted document text.
 $expected=if ($Composing) { "0,$($Snapshot.Length)" } else { '-' }
 if ($Snapshot.Composition -ne $expected) {
  throw "Composition mismatch $Name expected=$expected actual=$($Snapshot.Composition)"
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
   }
   $tail=if ($case -eq 'async') { 'ASYNCFLUSH SETTLE30000:RESULT' } else { 'SETTLE30000:RESULT' }
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
   $word=switch ($case) { okuri {'6d883048308b'} next {'54c9'} default {'4eee540d'} }
   $expected=$word+$suffix
   if ($case -ne 'fast') {
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
   Assert-PunctComposition $snapshot ($case -eq 'preedit') $name
   $checks++
   if ($local -eq 1 -and $case -ne 'preedit' -and $text -notmatch 'branch=local-(okuri-)?convert') { throw "Missing local conversion: $name" }
   if ($local -eq 0 -and $text -match 'branch=local-(okuri-)?convert') { throw "Unexpected local conversion: $name" }
   $checks++; $completedCases++
   Write-Output "PASS punctuation case=$name log=$log"
  }
 }
 Write-Output "PASS punctuation cases=$completedCases checks=$checks artifacts=$run"
} finally { $env:DDSKK_HARNESS_DIAGNOSTICS=$saved }
