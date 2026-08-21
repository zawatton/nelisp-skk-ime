<#
.SYNOPSIS
  Verifies elapsed-use evidence, then runs the reproducible v1 test suite.

.DESCRIPTION
  This is the final NeLisp IME v1 release gate. It refuses incomplete or
  mismatched monitor evidence before invoking verify-v1.ps1.
#>
[CmdletBinding()]
param(
  [string]$StatusPath = "$env:LOCALAPPDATA\DDSKK\verification\v1-monitor-current.json",
  [switch]$SkipAutomated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Sha256([string]$Path) {
  $stream = [IO.File]::OpenRead($Path)
  try {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
      return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    } finally {
      $sha.Dispose()
    }
  } finally {
    $stream.Dispose()
  }
}

function Assert-Gate([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "V1 release evidence failed: $Message" }
}

$StatusPath = [IO.Path]::GetFullPath($StatusPath)
Assert-Gate (Test-Path -LiteralPath $StatusPath) "status not found: $StatusPath"
$status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
Assert-Gate ($status.schema -eq 1) 'unsupported monitor status schema'
Assert-Gate (Test-Path -LiteralPath $status.log) "JSONL log not found: $($status.log)"
Assert-Gate (Test-Path -LiteralPath $status.monitor_script) `
  "frozen monitor not found: $($status.monitor_script)"
Assert-Gate ((Get-Sha256 $status.monitor_script) -eq $status.monitor_sha256) `
  'frozen monitor SHA-256 mismatch'
Assert-Gate ($status.failures -eq 0) "monitor recorded $($status.failures) failures"
Assert-Gate ([bool]$status.soak_complete) '24-hour active soak is incomplete'
Assert-Gate ([bool]$status.normal_use_complete) 'seven-day normal-use period is incomplete'
Assert-Gate (($status.continuous_samples * $status.sample_seconds) -ge (24 * 3600)) `
  'continuous active samples are shorter than 24 hours'
Assert-Gate (((Get-Date) - [datetime]$status.started).TotalDays -ge 7) `
  'less than seven wall-clock days have elapsed'
Assert-Gate ($status.max_host_bytes -le ($status.memory_limit_mib * 1MB)) `
  'host private memory exceeded its limit'
Assert-Gate ($status.max_child_bytes -le ($status.memory_limit_mib * 1MB)) `
  'provider private memory exceeded its limit'
Assert-Gate ($status.max_sumi_bytes -le ($status.memory_limit_mib * 1MB)) `
  'Sumi private memory exceeded its limit'
foreach ($name in @('notepad','edge','terminal','emacs')) {
  Assert-Gate ([bool]$status.app_matrix.$name) "$name did not load the exact release DLL"
}

$native = Get-ItemProperty 'HKCU:\Software\NativeIME'
$registeredDll = [string](Get-ItemProperty `
  'HKCU:\Software\Classes\CLSID\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\InprocServer32').'(default)'
Assert-Gate ([IO.Path]::GetFullPath([string]$native.EngineHost) -eq $status.expected_host) `
  'registered engine host changed during the release run'
Assert-Gate ([IO.Path]::GetFullPath([string]$native.Repository) -eq $status.expected_repository) `
  'registered engine snapshot changed during the release run'
Assert-Gate ([IO.Path]::GetFullPath([string]$native.SettingsExe) -eq $status.expected_sumi) `
  'registered Sumi executable changed during the release run'
Assert-Gate ([IO.Path]::GetFullPath($registeredDll) -eq $status.expected_dll) `
  'registered TSF DLL changed during the release run'

$records = @(Get-Content -LiteralPath $status.log | ForEach-Object {
  $_ | ConvertFrom-Json
})
$soak = @($records | Where-Object { $_.type -eq 'soak-milestone' } | Select-Object -Last 1)
$complete = @($records | Where-Object { $_.type -eq 'complete' -and -not $_.test_run } |
  Select-Object -Last 1)
Assert-Gate ($soak.Count -eq 1 -and [bool]$soak[0].pass) `
  'passing soak milestone is absent from JSONL evidence'
Assert-Gate ($complete.Count -eq 1 -and [bool]$complete[0].pass) `
  'passing final completion record is absent from JSONL evidence'

Write-Host 'ELAPSED V1 RELEASE EVIDENCE: PASS'
if (-not $SkipAutomated) {
  & (Join-Path $PSScriptRoot 'verify-v1.ps1')
  if ($LASTEXITCODE -ne 0) { throw "automated verification exited $LASTEXITCODE" }
}
Write-Host 'NELISP IME V1 RELEASE: PASS'
