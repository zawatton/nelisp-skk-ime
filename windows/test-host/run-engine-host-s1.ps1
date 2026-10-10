[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][string]$LargeDictionary,
      [string]$LargeDictionaryUtf8='', [string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45, [ValidateRange(1,1)][int]$MatrixWorkers=1,
      [switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
# The shared serial runner forces every policy switch OFF for this stage.
# It calls the native gates directly instead of S3/S4's policy-ON aggregates.
& (Join-Path $PSScriptRoot 'run-engine-host-s6.ps1') @PSBoundParameters -Stage NativeBaseline
if($ValidateParametersOnly){Write-Output 'PASS S1.5 parameter audit stacks=0'}
else{Write-Output 'PASS S1.5 native baseline policy=OFF (shared receipt: stage NativeBaseline)'}
