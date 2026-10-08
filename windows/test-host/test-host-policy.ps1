[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateSet('isolation','soak','replay')][string]$Mode='isolation',
      [string]$HostExecutable='', [int]$ColdLoadSleepSec=45,
      [ValidateSet('ddskk','lattice')][string]$Engine='ddskk',
      [string]$Fixture='docs/contracts/native-v1.json')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(-not $HostExecutable){$HostExecutable=Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"}
& python (Join-Path $PSScriptRoot 'host-policy.py') $Mode --runtime $Runtime --host $HostExecutable --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec --engine $Engine --fixture (Join-Path $root $Fixture)
exit $LASTEXITCODE
