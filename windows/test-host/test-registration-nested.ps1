[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [ValidateRange(0,1)][int[]]$LocalConversion = @(0,1),
  [int]$ColdLoadSleepSec = 45,
  [string]$ArtifactDirectory = '',
  [string]$OnlyCase = ''
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath($BuildDirectory)
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $root 'build/rg1-tsf' }
New-Item -ItemType Directory -Force $ArtifactDirectory | Out-Null
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
# Each run receives a new private user dictionary, pipe and registry key
# from run-harness.ps1. Never reuse a learned outer reading between cases.
$fixture = Join-Path $artifacts 'registration-jisyo.utf8'
[IO.File]::WriteAllText($fixture, ";; okuri-ari entries.`nかk /書/`n;; okuri-nasi entries.`nあい /愛/`nぱぱぱ /既存/`n", [Text.UTF8Encoding]::new($false))
$cases = @(
  @{name='plain-ret'; inner='A i SPACE'; word='て愛'},
  @{name='plain-follow'; inner='A i SPACE s u t o'; word='て愛すと'},
  @{name='okuri-ret'; inner='K a K u'; word='て書く'},
  @{name='okuri-follow'; inner='K a K u s u t o'; word='て書くすと'},
  @{name='cancel-idle'; inner=''; quits=0},
  @{name='cancel-prefix'; inner='k'; quits=1},
  @{name='cancel-reading'; inner='A i'; quits=1},
  @{name='cancel-candidate'; inner='A i SPACE'; quits=2},
  @{name='cancel-okuri'; inner='K a K u'; quits=2},
  @{name='recursive-miss-ret'; inner='P i p i p i SPACE a i ENTER'; word='てあい'; childKeys='P i p i p i'; childWord='あい'; registrations=2},
  @{name='recursive-exhaust-ret'; inner='A i SPACE SPACE s u ENTER'; word='てす'; childKeys='A i'; childWord='す'; registrations=2},
  @{name='recursive-depth3-ret'; inner='P i p i p i SPACE s u P u p u p u SPACE t o ENTER ENTER'; word='てすと'; registrations=3},
  @{name='recursive-miss-cancel'; inner='P i p i p i SPACE'; quits=2},
  @{name='recursive-exhaust-cancel'; inner='A i SPACE SPACE'; quits=3},
  @{name='recursive-depth3-cancel'; inner='P i p i p i SPACE P u p u p u SPACE'; quits=4}

)
function Checkpoint([string]$text, [string]$label) {
  $matches = [regex]::Matches($text, '(?m)^AFTER ' + [regex]::Escape($label) + ' BUF=\[(.*)\] SEL=.* COMP=(.*)$')
  if ($matches.Count -ne 1) { throw "Expected one checkpoint $label; got $($matches.Count)" }
  $match = $matches[0]
  return @($match.Groups[1].Value, $match.Groups[2].Value.Trim())
}
# Validate provider evidence separately from rendered checkpoint text: a
# parked reading can otherwise resemble a completed depth-three word.
function AssertWordProviderEvidence([string]$text, [string]$name, [int]$expected, [bool]$localLearning) {
  if ($text -notmatch '(?m)^PROVIDER_SETTINGS engine=\S+ applied=1\b') {
    throw "Provider settings never applied: $name"
  }
  if ($localLearning) {
    $staged = [regex]::Matches($text, '(?m)^REGISTRATION_LEARNING queued=1(?:\s|$)').Count
    if ($staged -ne $expected) { throw "Expected $expected confirmed registration learnings: $name got=$staged" }
  }
  $retained = $false
  foreach ($event in [regex]::Matches($text, '(?m)^(?:PROVIDER_SETTINGS pending=1 conversion_retained=1|PROVIDER_SETTINGS conversion_resumed=1|LOCAL_FALLBACK resolved=candidate pending=0)\b')) {
    $retained = $event.Value -eq 'PROVIDER_SETTINGS pending=1 conversion_retained=1'
  }
  if ($retained) { throw "Provider conversion retained but never resumed: $name" }
}
$saved = @{}
foreach ($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_KEYSTATE_AFTER_TEST','NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$checks = 0
$runs = 0
try {
  $env:DDSKK_DICTIONARY_FILES = $fixture
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  $env:NATIVEIME_TEST_KEYSTATE_AFTER_TEST = '1'
  # Reconversion must see confirmed learning before asynchronous remapping.
  $env:NATIVEIME_TEST_LOCAL_REMAP_DELAY_MS = '4000'
  foreach ($local in $LocalConversion) {
    foreach ($origin in @('miss','exhaust')) {
      $reading = if ($origin -eq 'miss') { 'P a p a p i' } else { 'P a p a p a' }
      $entry = $reading + ' SPACE SETTLE8000:FIRST '
      if ($origin -eq 'exhaust') { $entry += 'SPACE ' }
      foreach ($case in $cases) {
        $name = "$origin-$($case.name)-local$local"
        if ($OnlyCase -and $OnlyCase -ne $name) { continue }
        # No waits inside the inner word: exercise queued SPACE, candidate
        # acceptance by a following key, and queued RET under provider load.
        $tokens = 'CTX2 a i SPACE WAIT3000 ENTER CTX1 ' + $entry + 'SETTLE8000:REG t e ' + $case.inner + ' '
        if ($case.ContainsKey('word')) {
          $tokens += 'ENTER SETTLE8000:END APPCLEAR ' + $reading + ' SPACE SETTLE8000:LEARN ENTER SETTLE8000:REINSERT'
          if ($case.ContainsKey('childKeys')) {
            $tokens += ' APPCLEAR ' + $case.childKeys + ' SPACE ENTER SETTLE8000:CHILDLEARN'
          }
        } else {
          for ($i=0; $i -lt $case.quits; $i++) {
            $tokens += "CTRLG SETTLE8000:INNER$i "
          }
          $tokens += 'CTRLG SETTLE8000:OUTER CTRLG '
          if ($origin -eq 'exhaust') { $tokens += 'SETTLE8000:RESTORED-READING CTRLG ' }
          $tokens += 'SETTLE8000:CLEAR ' + $entry + 'SETTLE8000:UNLEARNED CTRLG SETTLE8000:QUIT1 CTRLG '
          if ($origin -eq 'exhaust') { $tokens += 'SETTLE8000:QUIT2 CTRLG ' }
          $tokens += 'SETTLE8000:END'
        }
        $log = Join-Path $artifacts "$name.log"
        $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
          -Script $tokens -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
          -CoreDllPath (Join-Path $build 'ddskk-ime-core.dll') `
          -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') `
          -TsfHostExe (Join-Path $build 'tsf-host.exe') -EngineExecutablePath $EngineExecutablePath `
          -ArtifactDirectory (Join-Path $artifacts $name) `
          -LocalConversion $local -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 240 2>&1)
        $result = $LASTEXITCODE
        $lines | Set-Content -LiteralPath $log -Encoding UTF8
        if ($result -ne 0) { throw "Harness failed: $name ($result), see $log" }
        # Validate original UTF-8 host bytes: the outer PowerShell console
        # may transcode Japanese characters before returning captured lines.
        $hostLog = Get-ChildItem -LiteralPath (Join-Path $artifacts $name) -Recurse -Filter 'tsf.stdout.log' |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $hostLog) { throw "No UTF-8 host log: $name" }
        $text = Get-Content -LiteralPath $hostLog.FullName -Raw -Encoding UTF8
        if ($text -notmatch 'KEYSTATE_AFTER_TEST injected=1') { throw "Modifier-race negative control missing: $name" }
        $end = Checkpoint $text 'END'
        if ($case.ContainsKey('word')) {
          $expected = if ($case.ContainsKey('registrations')) { $case.registrations } else { 1 }
          AssertWordProviderEvidence $text $name $expected ($local -eq 1)
        }
        if ($local -eq 1) {
          $staged = [regex]::Matches($text, '(?m)^REGISTRATION_LEARNING queued=1(?:\s|$)').Count
          if ($case.ContainsKey('word')) {
            # Count every confirmed frame: outer plus confirmed inner ones.
            # Candidate acceptance inside the editor is not a registration.
            if ($text -notmatch 'LOCAL_MAPPING delay_ms=4000 retained=1') { throw "Remap-delay negative control missing: $name" }
          } elseif ($staged -ne 0) { throw "Cancelled registration staged learning: $name" }
        }
        if ($case.ContainsKey('word')) {
          if ($end[0] -cne $case.word -or $end[1] -ne '-') { throw "Wrong/duplicated/uncommitted word: $name ($($end -join ', '))" }
          $again = Checkpoint $text 'REINSERT'
          if ($again[0] -cne $case.word -or $again[1] -ne '-') { throw "Learning failed: $name" }
          $checks += 2
          if ($case.ContainsKey('childWord')) {
            $child = Checkpoint $text 'CHILDLEARN'
            if ($child[0] -cne $case.childWord -or $child[1] -ne '-') { throw "Inner learning failed: $name" }
            $checks++
          }
        } else {
          if ($end[0] -ne '' -or $end[1] -ne '-') { throw "Cancelled text leaked: $name" }
          for ($i=0; $i -lt $case.quits; $i++) {
            $inside = Checkpoint $text "INNER$i"
            $parked = Checkpoint $text 'REG'
            if ($inside[0] -cne $parked[0]) { throw "Nested cancel edited document: $name" }
            $checks++
          }
          $unlearned = Checkpoint $text 'UNLEARNED'
          $original = Checkpoint $text 'REG'
          if ($unlearned[0] -cne $original[0]) { throw "Cancelled registration was learned: $name" }
          $checks++
          # A cancelled outer word must still miss/exhaust into registration.
          if ($text -notmatch 'branch=registration-async') { throw "No registration ownership: $name" }
          $checks++
        }
        # Before outer RET, nested text must never appear in the document.
        $parked = Checkpoint $text 'REG'
        if ($parked[0] -match '愛|書|て') { throw "Registration entry leaked inner text: $name" }
        $checks++
        $runs++
        Write-Output "MATCH $name checks=$checks log=$log"
      }
    }
  }
  if ($runs -eq 0) { throw 'No cases selected' }
  Write-Output "PASS RG1 TSF runs=$runs assertions=$checks"
} finally {
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
