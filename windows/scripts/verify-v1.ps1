<#
.SYNOPSIS
  Builds and runs the complete reproducible NeLisp IME v1 verification set.

.DESCRIPTION
  This is the command of record for the automated portion of
  docs/v1-goals.md. It uses only private test pipes/dictionaries and does not
  deploy or stop the live IME. The 24-hour and seven-day elapsed-use gates are
  intentionally reported separately because they cannot be manufactured by a
  short automated run.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$EmacsExe = 'emacs',
  [string]$IndicatorExe = '',
  [int]$ColdLoadSleepSec = 12,
  [switch]$SkipBuild,
  [switch]$SkipLongRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
if (-not $IndicatorExe) {
  $IndicatorExe = Join-Path $RepoRoot 'sumi-ui\target\sumi-skk-ui.exe'
}
$IndicatorExe = [IO.Path]::GetFullPath($IndicatorExe)
$buildDir = Join-Path $RepoRoot 'windows\build'

function Invoke-Gate {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][scriptblock]$Action
  )
  Write-Host "`n=== $Name ==="
  & $Action
  if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE" }
  Write-Host "PASS: $Name"
}

Push-Location $RepoRoot
try {
  if (-not $SkipBuild) {
    Invoke-Gate 'Windows Release build' {
      cmake -S windows -B $buildDir
      if ($LASTEXITCODE -eq 0) { cmake --build $buildDir --config Release }
    }
  }

  Invoke-Gate 'Windows CTest' {
    ctest --test-dir $buildDir -C Release --output-on-failure
  }

  Invoke-Gate 'Framework and Lattice ERT' {
    $ertFiles = @(rg --files framework/test engines/lattice/test |
      Where-Object { $_ -like '*.el' } | Sort-Object)
    if ($ertFiles.Count -eq 0) { throw 'No ERT files found.' }
    $ertArgs = @('-Q', '--batch', '-L', 'framework/src', '-L',
                 'engines/lattice/src')
    foreach ($file in $ertFiles) { $ertArgs += @('-l', $file) }
    $ertArgs += @('-f', 'ert-run-tests-batch-and-exit')
    & $EmacsExe @ertArgs
  }

  Invoke-Gate 'DDSKK TSF behavior' {
    & powershell -ExecutionPolicy Bypass -File `
      windows/test-host/test-ddskk-behavior.ps1 `
      -ColdLoadSleepSec $ColdLoadSleepSec
  }

  Invoke-Gate 'Lattice TSF behavior' {
    & powershell -ExecutionPolicy Bypass -File `
      windows/test-host/test-lattice-behavior.ps1 `
      -ColdLoadSleepSec $ColdLoadSleepSec
  }

  Invoke-Gate 'Ordinary-key latency and integrity' {
    $keyCount = if ($SkipLongRun) { 1000 } else { 10000 }
    & powershell -ExecutionPolicy Bypass -File `
      windows/test-host/measure-latency.ps1 -KeyCount $keyCount `
      -ColdLoadSleepSec $ColdLoadSleepSec -Enforce
  }

  if (-not (Test-Path -LiteralPath $IndicatorExe)) {
    throw "Sumi executable not found: $IndicatorExe"
  }
  $engineHost = Join-Path $buildDir 'Release\ddskk-engine-host.exe'
  Invoke-Gate 'Sumi mode transitions' {
    & powershell -ExecutionPolicy Bypass -File sumi-ui/verify/verify.ps1 `
      -IndicatorExe $IndicatorExe -EngineHost $engineHost `
      -Repository $RepoRoot -ColdLoadSleepSec $ColdLoadSleepSec
  }
  Invoke-Gate 'Sumi settings persistence' {
    & powershell -ExecutionPolicy Bypass -File `
      sumi-ui/verify/verify-settings.ps1 -IndicatorExe $IndicatorExe
  }
  Invoke-Gate 'Settings window identity' {
    & powershell -ExecutionPolicy Bypass -File `
      sumi-ui/verify/verify-settings-window-title.ps1 -Root $RepoRoot
  }

  Write-Host "`nAUTOMATED V1 VERIFICATION: PASS"
  Write-Host 'Elapsed gates still require recorded 24-hour and seven-day evidence.'
} finally {
  Pop-Location
}
