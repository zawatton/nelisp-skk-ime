# Coordinator-only HN8 gate: exactly one private stack, ON then SHADOW.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,[switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
if(-not $build.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)){throw 'Private build directory required'}
if($ValidateParametersOnly){
  & python -B (Join-Path $PSScriptRoot 'test-host-native-merge.py') --self-test
  if($LASTEXITCODE -ne 0){throw 'HN8 checker self-test failed'}
  return
}
& python -B (Join-Path $PSScriptRoot 'test-host-native-merge.py') --runtime $Runtime --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec
if($LASTEXITCODE -ne 0){throw 'HN8 private stack gate failed; see retained artifacts'}
