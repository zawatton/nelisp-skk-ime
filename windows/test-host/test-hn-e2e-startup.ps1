# Coordinator-only HN9; dry mode starts no host/stack.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,[switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
if(-not $build.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)){throw 'Private build directory required'}
if($ValidateParametersOnly){
  & python -B (Join-Path $PSScriptRoot 'test-hn-e2e-startup.py') --self-test
  if($LASTEXITCODE -ne 0){throw 'HN9 checker self-test failed'}
  return
}
foreach($name in @('HN_NATIVE_RUNTIME','HN_NELISP_SRC')){
  if(-not [Environment]::GetEnvironmentVariable($name)){throw "Missing required environment: $name"}
}
# Offline native preparation occurs before the bounded stack phase.
& python -B (Join-Path $PSScriptRoot 'test-hn-e2e-startup.py') --runtime $Runtime --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec
if($LASTEXITCODE -ne 0){throw 'HN9 private gate failed; see retained artifacts'}
