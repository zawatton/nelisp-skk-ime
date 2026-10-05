[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$DllPath,
  [Parameter(Mandatory)][string]$TsfHostExe,
  [Parameter(Mandatory)][string]$EngineHostPath,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [string]$RepositoryPath = "",
  [int]$ColdLoadSleepSec = 45,
  [ValidateSet('latin','hiragana','katakana','restore','abrupt')]
  [string[]]$Modes = @('latin','hiragana','katakana','restore','abrupt')
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ($RepositoryPath) { $root = [IO.Path]::GetFullPath($RepositoryPath) }
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$assertions = 0
foreach ($mode in $Modes) {
  # Each CLIENT pumps the real DLL publication queue and reads our private key.
  $script = 'IMEOFF CLIENT IMEON CLIENT CLIENT CTRLJ q CLIENT q CLIENT K a CLIENT SPACE WAIT3000 CLIENT ENTER WAIT500 CLIENT'
  $openMode = $mode
  if ($mode -eq 'abrupt') { $openMode = 'latin'; $script = 'IMEOFF CLIENT IMEON CLIENT EXITNOW' }
  $lines = @(& powershell -ExecutionPolicy Bypass -File $harness -Script $script `
    -DllPath $DllPath -TsfHostExe $TsfHostExe -EngineHostPath $EngineHostPath `
    -EngineExecutablePath $EngineExecutablePath -RepositoryPath $root `
    -ColdLoadSleepSec $ColdLoadSleepSec -OpenMode $openMode -PublishState 2>&1)
  $lines | ForEach-Object { Write-Output $_ }
  if ($LASTEXITCODE -ne 0) { throw "Harness failed for $mode" }
  if ($mode -eq 'abrupt') {
    if (($lines -join "`n") -notmatch 'CLIENT_ABRUPT_EXIT' -or
        ($lines -join "`n") -notmatch 'CLIENT_EXIT_REMOVED=1') { throw 'Dead-PID cleanup failed' }
    $assertions += 1
    Write-Output 'DEADPID PASS assertions=1'
    continue
  }
  $states = @($lines | Where-Object { $_ -match '^CLIENT mode=' } | ForEach-Object {
    if ($_ -match '^CLIENT mode=(\S+) open=(\d+) composing=(\d+) sequence=(\d+)') {
      [pscustomobject]@{ Mode=$Matches[1]; Open=[int]$Matches[2]; Composing=[int]$Matches[3]; Sequence=[int]$Matches[4] }
    }
  })
  if ($states.Count -ne 8) { throw "Expected 8 snapshots for $mode, got $($states.Count)" }
  if ($states[0].Open -ne 0 -or $states[1].Open -ne 1) { throw 'Open compartment not published' }
  $expected = if ($mode -eq 'restore') { 'hiragana' } else { $mode }
  if ($states[1].Mode -ne $expected) { throw "OpenMode=$mode yielded $($states[1].Mode)" }
  if ($states[2].Sequence -ne $states[1].Sequence) { throw 'Idle state was rewritten' }
  if ($states[3].Mode -ne 'katakana' -or $states[4].Mode -ne 'hiragana') { throw 'Mode changes not published' }
  if ($states[5].Composing -ne 1 -or $states[6].Composing -ne 2 -or $states[7].Composing -ne 0) {
    throw 'Reading / candidate / committed states not published'
  }
  for ($index=1; $index -lt $states.Count; $index++) {
    if ($index -ne 2 -and $states[$index].Sequence -le $states[$index-1].Sequence) { throw 'Sequence did not advance' }
  }
  if (($lines -join "`n") -notmatch 'CLIENT_EXIT_REMOVED=1') { throw 'Client entry not removed on exit' }
  $assertions += 8
  Write-Output "OPENMODE=$mode PASS assertions=8"
}
Write-Output "PASS emacs integration assertions=$assertions cases=$($Modes.Count)"
