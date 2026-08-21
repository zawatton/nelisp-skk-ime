[CmdletBinding()]
param(
  [ValidateSet('ddskk', 'lattice')][string]$Engine = 'ddskk',
  [int]$Iterations = 20,
  [int]$CandidateDeadlineMs = 150,
  [double]$AcknowledgementLimitMs = 16.0,
  [int]$ColdLoadSleepSec = 12,
  [string]$DllPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
if ($Iterations -lt 20 -or $CandidateDeadlineMs -lt 1) {
  throw 'at least 20 iterations and a positive candidate deadline are required'
}
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$hostExe = Join-Path $root 'windows\build\Release\ddskk-engine-host.exe'
$fixture = Join-Path $PSScriptRoot 'data\behavior-jisyo.utf8'
if (-not $DllPath) { $DllPath = Join-Path $root 'windows\build\Release\ddskk-ime.dll' }

$episode = if ($Engine -eq 'ddskk') {
  "K a SPACE WAIT$CandidateDeadlineMs ENTER WAIT500"
} else {
  "k a n a SPACE WAIT$CandidateDeadlineMs ENTER WAIT500"
}
$inputScript = ((1..$Iterations | ForEach-Object { $episode }) -join ' ')

$saved = @{
  engine = $env:NELISP_IME_ENGINE; dll = $env:DDSKK_HARNESS_DLL_PATH
  dictionaries = $env:DDSKK_DICTIONARY_FILES; enabled = $env:DDSKK_SKKSERV_ENABLE
  host = $env:DDSKK_SKKSERV_HOST; port = $env:DDSKK_SKKSERV_PORT
  diagnostics = $env:DDSKK_HARNESS_DIAGNOSTICS
}
try {
  $env:NELISP_IME_ENGINE = $Engine
  $env:DDSKK_HARNESS_DLL_PATH = [IO.Path]::GetFullPath($DllPath)
  $env:DDSKK_DICTIONARY_FILES = [IO.Path]::GetFullPath($fixture)
  $env:DDSKK_SKKSERV_ENABLE = '0'
  $env:DDSKK_SKKSERV_HOST = '127.0.0.1'
  $env:DDSKK_SKKSERV_PORT = '9'
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  $lines = @(& powershell -ExecutionPolicy Bypass -File $harness `
    -Script $inputScript -EngineHostPath $hostExe -RepositoryPath $root `
    -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "run-harness failed with exit code $LASTEXITCODE"
  }
} finally {
  foreach ($pair in @(
    @('NELISP_IME_ENGINE','engine'), @('DDSKK_HARNESS_DLL_PATH','dll'),
    @('DDSKK_DICTIONARY_FILES','dictionaries'), @('DDSKK_SKKSERV_ENABLE','enabled'),
    @('DDSKK_SKKSERV_HOST','host'), @('DDSKK_SKKSERV_PORT','port'),
    @('DDSKK_HARNESS_DIAGNOSTICS','diagnostics'))) {
    $value = $saved[$pair[1]]
    if ($null -eq $value) { Remove-Item "Env:$($pair[0])" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$($pair[0])" $value }
  }
}

$ackUs = @($lines | Where-Object { $_ -match '^KEYLAT token=SPACE .*total_us=(\d+) ' } |
  ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
$candidatePattern = '^CANDIDATEUI preview=1 count=[1-9][0-9]*$'
$candidateCount = @($lines | Where-Object { $_ -match $candidatePattern }).Count
$requiredCandidates = [Math]::Ceiling($Iterations * 0.95)
if ($ackUs.Count -ne $Iterations) {
  throw "conversion acknowledgement samples missing: $($ackUs.Count)/$Iterations"
}
$ackMaxMs = (($ackUs | Measure-Object -Maximum).Maximum / 1000.0)
if ($ackMaxMs -gt $AcknowledgementLimitMs) {
  throw "conversion acknowledgement exceeded $AcknowledgementLimitMs ms: $ackMaxMs ms"
}
if ($candidateCount -lt $requiredCandidates) {
  throw "first candidate missed p95 deadline: $candidateCount/$Iterations within $CandidateDeadlineMs ms"
}

[pscustomobject]@{
  Result = 'PASS'; Engine = $Engine; Iterations = $Iterations
  AcknowledgementMaxMs = [Math]::Round($ackMaxMs, 3)
  CandidateDeadlineMs = $CandidateDeadlineMs
  CandidatesWithinDeadline = $candidateCount
  RequiredForP95 = $requiredCandidates
}
