[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [Parameter(Mandatory)][string]$ArtifactDirectory,
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build = [IO.Path]::GetFullPath($BuildDirectory)
$saved = $env:DDSKK_HARNESS_DIAGNOSTICS
try {
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script 'K a n a q SETTLE30000:q K a ENTER SETTLE30000:next' `
    -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
    -CoreDllPath (Join-Path $build 'ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'tsf-host.exe') `
    -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
    -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory $ArtifactDirectory `
    -RomajiProbePath (Join-Path ([IO.Path]::GetFullPath($ArtifactDirectory)) 'q-rules.txt') -RomajiRulesOnly 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "q harness exit $LASTEXITCODE" }
  $text = $lines -join "`n"
  $assertions = 0
  foreach ($pattern in @('branch=q-katakana-local state=1',
                         'AFTER q BUF=\[\u30ab\u30ca\] SEL=2,2 COMP=-',
                         'AFTER next BUF=\[\u30ab\u30ca\u304b\] SEL=3,3 COMP=-',
                         'HARNESS_CHILD_EXITED .*exited=True')) {
    if ($text -notmatch $pattern) { throw "q assertion failed: $pattern" }
    $assertions++
  }
  if ($text -notmatch 'SETTLE OK token=SETTLE30000:q elapsed_ms=(\d+)' -or [int]$Matches[1] -gt 200) {
    throw 'q exceeded local settle budget'
  }
  $elapsed = [int]$Matches[1]
  Write-Output "PASS local-q TSF assertions=$($assertions + 1) settle_ms=$elapsed cleanup=confirmed"
} finally { $env:DDSKK_HARNESS_DIAGNOSTICS = $saved }
