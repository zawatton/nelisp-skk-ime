[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$DllPath,
  [Parameter(Mandatory)][string]$DelayedCoreDllPath,
  [Parameter(Mandatory)][string]$TsfHostExe,
  [Parameter(Mandatory)][string]$EngineHostPath,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [string]$RepositoryPath = '',
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ($RepositoryPath) { $root = [IO.Path]::GetFullPath($RepositoryPath) }
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'

function Run([string]$Keys) {
  $script:lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $harness `
    -Script $Keys -DllPath $DllPath -CoreDllPath $DelayedCoreDllPath `
    -TsfHostExe $TsfHostExe -EngineHostPath $EngineHostPath `
    -EngineExecutablePath $EngineExecutablePath -RepositoryPath $root `
    -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
  $script:code = $LASTEXITCODE
  $script:text = $script:lines -join "`n"
}
function Check([bool]$Condition, [string]$Label) {
  if (-not $Condition) {
    $script:lines | ForEach-Object { Write-Host $_ }
    throw "SETTLE test failed: $Label"
  }
}

# The CMake B core delays every provider worker by 400 ms. A quiet buffer
# alone would return too early here, while a composition-free idle check
# would never finish the reading/candidate observations.
Run 'K a SETTLE30000:READING SPACE SETTLE30000:CANDIDATE ENTER SETTLE30000:COMMIT'
Check ($code -eq 0) 'successful script'
Check ($text -match 'AFTER READING BUF=\[\u25bd\u304b\].*COMP=0,2') 'idle open preedit'
Check ($text -match 'AFTER CANDIDATE BUF=\[\u25bc\u868a\]' -and
       $text -match 'SETTLE OK token=SETTLE30000:CANDIDATE elapsed_ms=(\d+)' -and
       [int]$Matches[1] -ge 400) 'pending provider waited for and applied'
Check ($text -match 'AFTER COMMIT BUF=\[\u868a\].*COMP=-') 'idle committed buffer'

# Negative control: it must fail before that provider can complete, with
# both the pending observation and the failing script token in its message.
Run 'K a SPACE SETTLE50'
Check ($code -ne 0 -and $text -match
  'SETTLE TIMEOUT token=SETTLE50 .*max_ms=50 .*observed=1 provider_idle=0') 'pending timeout'
Write-Output 'PASS harness settle assertions=5 delayed_provider_ms=400 negative_controls=1'
