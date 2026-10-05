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
  # Observe the deferred swap on a following direct key, using the same
  # post-commit sequence as test-core-hot-swap before starting a new preedit.
  $keys = 'a CORE:B WAIT700 KEYSTATE:SHIFT a KEYSTATE:CLEAR K a CORE:production WAIT700 n a SPACE SETTLE30000 ENTER SETTLE30000 WAIT700 a WAIT700 K a n a Q SETTLE30000 ENTER SETTLE30000 K a KEYSTATE:SHIFT n KEYSTATE:CLEAR a q SETTLE30000:q'
  $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script $keys -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
    -TsfHostExe (Join-Path $build 'tsf-host.exe') `
    -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
    -CoreTestDirectory $build -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory $ArtifactDirectory 2>&1)
  if ($LASTEXITCODE -ne 0) { throw "Modifier harness exit $LASTEXITCODE" }
  $text = $lines -join "`n"
  $assertions = 0
  foreach ($pattern in @('SCRIPTKEY token=a inherited_shift=1 shift=0 control=0',
                         'SCRIPTKEY token=n inherited_shift=1 shift=0 control=0',
                         'AFTER a BUF=\[\u3042\u3042\] SEL=2,2 COMP=-',
                         'CORE swapped version=production',
                         'branch=q-katakana-local state=1',
                         'AFTER q BUF=\[\u3042\u3042\u4eee\u540d\u3042\u304b\u306a\u30ab\u30ca\] SEL=9,9 COMP=-',
                         'HARNESS_CHILD_EXITED .*exited=True')) {
    if ($text -notmatch $pattern) { throw "Modifier regression failed: $pattern" }
    $assertions++
  }
  if ($text -match 'UnknownToken' -or $text -notmatch 'SETTLE OK token=SETTLE30000:q elapsed_ms=(\d+)') {
    throw 'Modifier regression did not settle'
  }
  Write-Output "PASS scripted keyboard assertions=$($assertions + 1) ambient_shift=2 q_settle_ms=$($Matches[1])"
} finally { $env:DDSKK_HARNESS_DIAGNOSTICS = $saved }
