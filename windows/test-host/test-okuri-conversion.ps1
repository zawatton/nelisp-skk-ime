[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [string]$RepositoryPath = '',
  [string]$DictionaryPath = '',
  [string]$ArtifactDirectory = '',
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
if ($RepositoryPath) { $root = [IO.Path]::GetFullPath($RepositoryPath) }
$build = [IO.Path]::GetFullPath($BuildDirectory)
if (-not $DictionaryPath) { $DictionaryPath = Join-Path $PSScriptRoot 'data/okuri-jisyo.utf8' }
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $root 'build/okuri-conversion' }
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$artifacts = [IO.Path]::GetFullPath($ArtifactDirectory)
$saved = @{}
foreach ($name in @('HOME','OKURI_DICTIONARY','OKURI_ARTIFACT_DIRECTORY',
                    'DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
  $env:OKURI_DICTIONARY = [IO.Path]::GetFullPath($DictionaryPath)
  $env:OKURI_ARTIFACT_DIRECTORY = $artifacts
  $env:HOME=[Environment]::GetFolderPath('UserProfile');
  & emacs -Q --batch -L (Join-Path $root 'vendor/ddskk') -L (Join-Path $root 'engine') `
    -l (Join-Path $root 'engine/test-okuri-input.el') -f ert-run-tests-batch-and-exit `
    *> (Join-Path $artifacts 'oracle.log')
  if ($LASTEXITCODE -ne 0) { throw 'Stock DDSKK oracle failed; see oracle.log' }
  $env:DDSKK_DICTIONARY_FILES = $env:OKURI_DICTIONARY
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  # Warm up in the other TSF context so oracle checkpoints start empty.
  $tokens = 'CTX2 a i SPACE WAIT3000 ENTER CTX1 ' +
      (Get-Content (Join-Path $artifacts 'harness.tokens') -Raw)
  $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script $tokens -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
    -CoreDllPath (Join-Path $build 'ddskk-ime-core.dll') `
    -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') `
    -TsfHostExe (Join-Path $build 'tsf-host.exe') -EngineExecutablePath $EngineExecutablePath `
    -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 240 2>&1)
  $lines | Set-Content (Join-Path $artifacts 'harness.log') -Encoding UTF8
  if ($LASTEXITCODE -ne 0) { throw 'Okuri harness failed; see harness.log' }
  $assertions = 0
  foreach ($record in (Get-Content (Join-Path $artifacts 'oracle.tsv'))) {
    $label, $mode, $expected = $record.Split("`t")
    $after = @($lines | Where-Object { $_ -match ('^AFTER ' + [regex]::Escape($label) + ' BUF=') })
    if ($after.Count -ne 1 -or $after[0] -notmatch ' BUF=\[(.*)\] SEL=') {
      throw "Missing checkpoint $label"
    }
    $actual = -join ($Matches[1].ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ })
    if ($actual -ne $expected) { throw "Stock mismatch $label ($mode): expected=$expected actual=$actual" }
    $assertions++
    Write-Output "MATCH $label mode=$mode text=$actual"
  }
  $latencies = @($lines | Where-Object { $_ -match '^KEYLAT token=(?:[A-Za-z]|BS|CTRLG) .*total_us=(\d+) ' } |
    ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
  $maximum = ($latencies | Measure-Object -Maximum).Maximum
  if ($latencies.Count -eq 0 -or $maximum -gt 25000) { throw "Key exceeded existing 25 ms limit: $maximum us" }
  Write-Output "PASS okuri conversion checkpoints=$assertions key_max_us=$maximum dictionary=$DictionaryPath"
} finally {
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
