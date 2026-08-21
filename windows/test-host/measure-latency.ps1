<#
.SYNOPSIS
  Measures the real TSF TestKeyDown + KeyDown critical path and optionally
  enforces the NeLisp IME v1.0 latency gate.

.DESCRIPTION
  Runs the isolated test host through run-harness.ps1, parses the KEYLAT lines
  emitted inside tsf-host, and reports distribution statistics.  KEYLAT stops
  before the harness's 15 ms message pump, so the result measures only work
  for which an application's UI thread is synchronously blocked.
#>
[CmdletBinding()]
param(
  [int]$KeyCount = 1000,
  [double]$MedianLimitMs = 5.0,
  [double]$P95LimitMs = 10.0,
  [double]$MaxLimitMs = 25.0,
  [switch]$Enforce,
  [string]$DllPath = "",
  [int]$ColdLoadSleepSec = 12
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
if ($KeyCount -lt 2 -or ($KeyCount % 2) -ne 0) {
  throw 'KeyCount must be an even number of at least 2.'
}

$scriptRoot = $PSScriptRoot
$runHarness = Join-Path $scriptRoot 'run-harness.ps1'
if ([string]::IsNullOrWhiteSpace($DllPath)) {
  $DllPath = Join-Path $scriptRoot '..\build\Release\ddskk-ime.dll'
}
$DllPath = [IO.Path]::GetFullPath($DllPath)
if (-not (Test-Path -LiteralPath $DllPath)) {
  throw "DLL not found: $DllPath"
}

# Alternating k/a exercises pending-romaji and resolved-kana paths without
# conversion/dictionary cost.  Those have separate gates in v1-goals.md.
$tokens = for ($i = 0; $i -lt $KeyCount; $i++) {
  if (($i % 2) -eq 0) { 'k' } else { 'a' }
}
$keyScript = $tokens -join ' '
$previousDll = $env:DDSKK_HARNESS_DLL_PATH
$previousCompact = $env:NELISP_IME_HARNESS_COMPACT
$env:DDSKK_HARNESS_DLL_PATH = $DllPath
$env:NELISP_IME_HARNESS_COMPACT = '1'
try {
  $repository = [IO.Path]::GetFullPath((Join-Path $scriptRoot '..\..'))
  $engineHost = Join-Path $repository 'windows\build\Release\ddskk-engine-host.exe'
  $output = & powershell -ExecutionPolicy Bypass -File $runHarness `
    -Script $keyScript -ColdLoadSleepSec $ColdLoadSleepSec `
    -EngineHostPath $engineHost -RepositoryPath $repository `
    -TsfHostTimeoutSec 300 2>&1
  if ($LASTEXITCODE -ne 0) {
    $output | ForEach-Object { Write-Host $_ }
    throw "run-harness failed with exit code $LASTEXITCODE"
  }
} finally {
  if ($null -eq $previousDll) {
    Remove-Item Env:DDSKK_HARNESS_DLL_PATH -ErrorAction SilentlyContinue
  } else {
    $env:DDSKK_HARNESS_DLL_PATH = $previousDll
  }
  if ($null -eq $previousCompact) {
    Remove-Item Env:NELISP_IME_HARNESS_COMPACT -ErrorAction SilentlyContinue
  } else {
    $env:NELISP_IME_HARNESS_COMPACT = $previousCompact
  }
}

$samples = @()
foreach ($line in $output) {
  if ([string]$line -match '^KEYLAT .* total_us=(\d+) ') {
    $samples += ([double]$Matches[1] / 1000.0)
  }
}
if ($samples.Count -ne $KeyCount) {
  throw "Expected $KeyCount KEYLAT samples, received $($samples.Count)."
}

# The alternating k/a stream must produce exactly one U+304B per pair.
# Length catches loss/duplication; FNV over the full UTF-16 buffer catches
# wrong or stale text without emitting an O(n^2) growing BUF line per key.
$expectedLength = [int]($KeyCount / 2)
$modulus = [System.Numerics.BigInteger]::Pow(2, 64)
$expectedHash = [System.Numerics.BigInteger]14695981039346656037
for ($i = 0; $i -lt $expectedLength; $i++) {
  $expectedHash = (($expectedHash -bxor [System.Numerics.BigInteger]0x304b) *
                   [System.Numerics.BigInteger]1099511628211) % $modulus
}
$expectedHashHex = ([UInt64]$expectedHash).ToString('x16')
$final = @($output | Where-Object { [string]$_ -match '^FINAL BUF_LEN=(\d+) BUF_FNV=([0-9a-f]{16})$' })
$finalMatch = if ($final.Count -eq 1) {
  [regex]::Match([string]$final[0], '^FINAL BUF_LEN=(\d+) BUF_FNV=([0-9a-f]{16})$')
} else { $null }
if ($null -eq $finalMatch -or -not $finalMatch.Success -or
    [int]$finalMatch.Groups[1].Value -ne $expectedLength -or
    $finalMatch.Groups[2].Value -ne $expectedHashHex) {
  throw "Final document mismatch: expected length=$expectedLength fnv=$expectedHashHex; observed=$($final -join '; ')"
}

$sorted = @($samples | Sort-Object)
function Get-Percentile([double[]]$Values, [double]$Fraction) {
  $index = [Math]::Ceiling($Values.Count * $Fraction) - 1
  if ($index -lt 0) { $index = 0 }
  if ($index -ge $Values.Count) { $index = $Values.Count - 1 }
  return $Values[$index]
}

$result = [pscustomobject]@{
  Keys = $samples.Count
  MeanMs = [Math]::Round(($samples | Measure-Object -Average).Average, 3)
  MedianMs = [Math]::Round((Get-Percentile $sorted 0.50), 3)
  P95Ms = [Math]::Round((Get-Percentile $sorted 0.95), 3)
  P99Ms = [Math]::Round((Get-Percentile $sorted 0.99), 3)
  MaxMs = [Math]::Round(($samples | Measure-Object -Maximum).Maximum, 3)
  MedianLimitMs = $MedianLimitMs
  P95LimitMs = $P95LimitMs
  MaxLimitMs = $MaxLimitMs
}
$result

if ($Enforce -and
    ($result.MedianMs -gt $MedianLimitMs -or
     $result.P95Ms -gt $P95LimitMs -or
     $result.MaxMs -gt $MaxLimitMs)) {
  Write-Error ('Latency gate failed: median={0}ms p95={1}ms max={2}ms' -f `
    $result.MedianMs, $result.P95Ms, $result.MaxMs)
  exit 1
}
