[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w',
      [string]$InputRulesFile='build/live-input-rules.conf',
      [int]$ColdLoadSleepSec=45)
# One refused confirmation must retain the original key exactly once, then
# deliver the candidate and fresh episode in different locks after retry.
& (Join-Path $PSScriptRoot 'test-punct-commit.ps1') @PSBoundParameters `
  -Cases @('period-denied','letter-denied','okuri-denied')
