[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [string]$HostExecutable='', [int]$ColdLoadSleepSec=45,
      [ValidateSet('capture','replay')][string]$Mode='replay',
      [ValidateSet('ddskk','lattice')][string]$Engine='ddskk',
      [string]$Fixture='docs/contracts/native-v1.json')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(-not $HostExecutable){$HostExecutable=Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"}
& python (Join-Path $PSScriptRoot 'host-contracts.py') $Mode --runtime $Runtime --host $HostExecutable --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec --engine $Engine --fixture (Join-Path $root $Fixture)
exit $LASTEXITCODE
