[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [string]$HostExecutable='',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if(-not $HostExecutable){$HostExecutable=Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"}
& python (Join-Path $PSScriptRoot 'host-contracts.py') soak --runtime $Runtime --host $HostExecutable --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec
exit $LASTEXITCODE
