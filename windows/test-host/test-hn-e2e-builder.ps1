[CmdletBinding()]
param([string]$Runtime, [string]$PolicyRuntime, [string]$Bundle,
      [string]$BuildDir='build/w', [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,
      [Alias('self-test')][switch]$SelfTest)
$ErrorActionPreference='Stop'
$checker=Join-Path $PSScriptRoot 'test-hn-e2e-builder.py'
if ($SelfTest) {
  & python -B $checker --self-test
} else {
  if (-not $Runtime -or -not $PolicyRuntime -or -not $Bundle) {
    throw 'Runtime, PolicyRuntime and Bundle are required'
  }
  & python -B $checker --runtime $Runtime --policy-runtime $PolicyRuntime --bundle $Bundle --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
