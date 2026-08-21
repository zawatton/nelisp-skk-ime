[CmdletBinding()]
param(
  [int]$ColdLoadSleepSec = 12,
  [string]$DllPath = ""
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$hostExe = Join-Path $root 'windows\build\Release\ddskk-engine-host.exe'
if ([string]::IsNullOrWhiteSpace($DllPath)) {
  $DllPath = Join-Path $root 'windows\build\Release\ddskk-ime.dll'
}

$script = @(
  # Conversion and explicit learning (the second candidate for はし is 端).
  'k a n a SPACE WAIT150 ENTER WAIT100'
  'h a s i SPACE WAIT500 SPACE ENTER WAIT500'
  'h a s i SPACE WAIT500 ENTER WAIT500'
  # Candidate cancellation, then segment selection and resize.
  'k a n a SPACE WAIT500 CTRLG CTRLG'
  'k y o u h a SPACE WAIT500 SLEFT WAIT500 SRIGHT WAIT500 LEFT RIGHT ENTER WAIT500'
  # Five standard transliterations.
  'k a n a F6 WAIT500 ENTER WAIT100'
  'k a n a F7 WAIT500 ENTER WAIT100'
  'k a n a F8 WAIT500 ENTER WAIT100'
  'k a n a F9 WAIT500 ENTER WAIT100'
  'k a n a F10 WAIT500 ENTER WAIT100'
  # No waits at either conversion boundary: queued keys must remain ordered.
  'k a n a SPACE k a SPACE ENTER WAIT500 WAIT500'
) -join ' '

$savedEngine = $env:NELISP_IME_ENGINE
$savedDll = $env:DDSKK_HARNESS_DLL_PATH
try {
  $env:NELISP_IME_ENGINE = 'lattice'
  $env:DDSKK_HARNESS_DLL_PATH = [IO.Path]::GetFullPath($DllPath)
  $lines = @(& powershell -ExecutionPolicy Bypass -File $harness `
      -Script $script -EngineHostPath $hostExe -RepositoryPath $root `
      -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "run-harness failed with exit code $LASTEXITCODE"
  }
} finally {
  if ($null -eq $savedEngine) { Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue } else { $env:NELISP_IME_ENGINE = $savedEngine }
  if ($null -eq $savedDll) { Remove-Item Env:DDSKK_HARNESS_DLL_PATH -ErrorAction SilentlyContinue } else { $env:DDSKK_HARNESS_DLL_PATH = $savedDll }
}

$script:latticeText = $lines -join "`n"
function Require([string]$pattern, [string]$label) {
  if ($script:latticeText -notmatch $pattern) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "Lattice behavior failed: $label"
  }
}

# ASCII-only regexes keep Windows PowerShell 5.1 source decoding harmless.
Require 'AFTER WAIT150 BUF=\[\u4eee\u540d\].*COMP=0,2' 'warm first candidate within 150 ms'
Require 'AFTER WAIT500 BUF=\[[^\]]*\u7aef\u7aef\].*COMP=' 'learning promotes the selected candidate'
Require 'AFTER CTRLG BUF=\[[^\]]*\u25bd\u304b\u306a\]' 'candidate cancellation restores reading'
foreach ($token in @('LEFT','RIGHT','SLEFT','SRIGHT','F6','F7','F8','F9','F10')) {
  Require ("KEYLAT token={0} .*claimed=1" -f $token) "claimed Lattice control $token"
}
$controls = @($lines | Where-Object { $_ -match '^KEYLAT token=(LEFT|RIGHT|SLEFT|SRIGHT|F[6-9]|F10) .*total_us=(\d+) ' } |
  ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
if ($controls.Count -ne 9 -or ($controls | Measure-Object -Maximum).Maximum -gt 20000) {
  throw "Lattice behavior failed: provider control exceeded 20 ms ($($controls -join ',') us)"
}
Require 'AFTER WAIT500 BUF=\[[^\r\n]*\uff4b\uff41\uff4e\uff41' 'F9 wide Latin'
Require 'AFTER WAIT500 BUF=\[[^\r\n]*kana' 'F10 direct Latin'
Require 'AFTER WAIT500 BUF=\[[^\r\n]*\u4eee\u540d\u304b' 'queued fast input remains ordered'

$ordinary = @($lines | Where-Object { $_ -match '^KEYLAT token=[A-Za-z] .*total_us=(\d+) ' } |
  ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
if ($ordinary.Count -eq 0 -or ($ordinary | Measure-Object -Maximum).Maximum -gt 25000) {
  throw 'Lattice behavior failed: ordinary key exceeded 25 ms'
}

[pscustomobject]@{
  Result = 'PASS'
  OrdinaryMaxMs = [Math]::Round((($ordinary | Measure-Object -Maximum).Maximum / 1000.0), 3)
  ControlMaxMs = [Math]::Round((($controls | Measure-Object -Maximum).Maximum / 1000.0), 3)
  Assertions = 17
}
