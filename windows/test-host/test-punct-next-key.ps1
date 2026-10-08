[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [string]$InputRulesFile='build/live-input-rules.conf',
      [int]$ColdLoadSleepSec=45)
& (Join-Path $PSScriptRoot 'test-punct-commit.ps1') @PSBoundParameters `
  -Cases @('letter','reading','letter-fast','letter-async','typeahead')
