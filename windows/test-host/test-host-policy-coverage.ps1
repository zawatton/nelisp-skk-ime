# Coordinator-only S4.2 gate; dry validation starts no processes or registry changes.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,[switch]$ValidateParametersOnly)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
if(-not $build.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar)){throw 'Private build directory required'}
if($ValidateParametersOnly){
  & python -B (Join-Path $PSScriptRoot 'test-host-policy-coverage.py') --self-test
  if($LASTEXITCODE -ne 0){throw 'FAIL policy coverage dry validation'}
  Write-Output 'PASS policy coverage parameters stacks=0 cold_load=45';return
}
$bin=Join-Path $build 'Release'
foreach($file in @($Runtime,(Join-Path $bin 'ddskk-ime.dll'),(Join-Path $bin 'ddskk-ime-core.dll'),
    (Join-Path $bin 'ddskk-engine-host.exe'),(Join-Path $bin 'tsf-host.exe'))) {
  if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing file: $file"}
}
$names=@('NATIVEIME_TEST_CALLBACK_IO_PROBE','NATIVEIME_TEST_CALLBACK_WAIT_CONTROL','DDSKK_HARNESS_DIAGNOSTICS',
  'DDSKK_HOST_POLICY_COUNTERS','DDSKK_HOST_POLICY_SHADOW','DDSKK_HOST_POLICY_TEST_PAUSE_KIND',
  'DDSKK_HOST_POLICY_SOURCES','DDSKK_HOST_POLICY_CACHE','DDSKK_HOST_POLICY_RESTART','DDSKK_HOST_POLICY_PUBLICATION',
  'DDSKK_HOST_POLICY_LEARNING','DDSKK_HOST_LOG','DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE',
  'DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT','DDSKK_SKKSERV_START_COMMAND','NELISP_IME_ENGINE')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
  $env:NATIVEIME_TEST_CALLBACK_IO_PROBE='1';$env:NATIVEIME_TEST_CALLBACK_WAIT_CONTROL='0'
  $env:DDSKK_HARNESS_DIAGNOSTICS='1';$env:DDSKK_HOST_POLICY_COUNTERS='1';$env:DDSKK_HOST_POLICY_SHADOW='0'
  foreach($name in $names | Where-Object {$_ -match '^DDSKK_HOST_POLICY_(SOURCES|CACHE|RESTART|PUBLICATION|LEARNING)$'}) {
    [Environment]::SetEnvironmentVariable($name,'1')
  }
  [Environment]::SetEnvironmentVariable('DDSKK_HOST_POLICY_TEST_PAUSE_KIND',$null)
  [Environment]::SetEnvironmentVariable('DDSKK_SKKSERV_START_COMMAND',$null)
  $env:NELISP_IME_ENGINE='ddskk';$env:DDSKK_DICTIONARY_FILES=Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8'
  & python -B (Join-Path $PSScriptRoot 'test-host-policy-coverage.py') --runtime $Runtime --build-dir $BuildDir --cold-load-sleep-sec $ColdLoadSleepSec
  if($LASTEXITCODE -ne 0){throw 'FAIL policy coverage (see counts and retained artifacts)'}
} finally {foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
