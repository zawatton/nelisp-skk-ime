[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$DllPath,
  [Parameter(Mandatory=$true)][string]$TsfHostExe,
  [Parameter(Mandatory=$true)][string]$EngineHostPath,
  [Parameter(Mandatory=$true)][string]$EngineExecutablePath,
  [Parameter(Mandatory=$true)][string]$BuildDirectory,
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$savedDll = $env:DDSKK_HARNESS_DLL_PATH
$savedDiagnostics = $env:DDSKK_HARNESS_DIAGNOSTICS
$savedEngine = $env:NELISP_IME_ENGINE
function RunCase([string]$name, [string]$script, [string]$pattern) {
  $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $harness `
    -TsfHostExe $TsfHostExe -EngineHostPath $EngineHostPath `
    -EngineExecutablePath $EngineExecutablePath -RepositoryPath $root `
    -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 120 -Script $script 2>&1)
  $exitCode = $LASTEXITCODE
  $lines | Out-File -LiteralPath (Join-Path $BuildDirectory "harness-live-$name.log") -Encoding utf8
  $text = $lines -join "`n"
  if ($exitCode -ne 0 -or $text -notmatch $pattern) { throw "$name failed; see harness-live-$name.log" }
  if (@($lines | Where-Object { $_ -match '^TIP_DIRECT activate hr=' }).Count -ne 1) {
    throw "$name did not use exactly one activation"
  }
  Write-Output "PASS ${name}: one activation, conversion recovered"
}
try {
  $env:DDSKK_HARNESS_DLL_PATH = [IO.Path]::GetFullPath($DllPath)
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue
  RunCase 'switch' `
    'K a SPACE WAIT3000 ENTER WAIT500 ENGINE:lattice WAIT45000 a i SPACE WAIT3000 ENTER WAIT500 k a n a SPACE WAIT3000 ENTER WAIT500' `
    'AFTER WAIT500 BUF=\[\u868a\u5408\u3044\u4eee\u540d\].*COMP=-'
  RunCase 'recovery' `
    'K a SPACE WAIT3000 ENTER WAIT500 K a KILLHOST SPACE WAIT3000 CTRLG CTRLG WAIT45000 K a SPACE WAIT3000 ENTER WAIT500' `
    '(?s)TEST_KILL token=KILLHOST [^\r\n]*success=1.*PROVIDER done [^\r\n]*state=1.*AFTER WAIT500 BUF=\[\u868a\u868a\].*COMP=-'
} finally {
  [Environment]::SetEnvironmentVariable('DDSKK_HARNESS_DLL_PATH', $savedDll)
  [Environment]::SetEnvironmentVariable('DDSKK_HARNESS_DIAGNOSTICS', $savedDiagnostics)
  [Environment]::SetEnvironmentVariable('NELISP_IME_ENGINE', $savedEngine)
}
