[CmdletBinding()]
param(
  [int]$ColdLoadSleepSec = 12,
  [string]$DllPath = ""
)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$fixture = Join-Path $PSScriptRoot 'data\behavior-jisyo.utf8'
$hostExe = Join-Path $root 'windows\build\Release\ddskk-engine-host.exe'
if ([string]::IsNullOrWhiteSpace($DllPath)) {
  $DllPath = Join-Path $root 'windows\build\Release\ddskk-ime.dll'
}

$script = @(
  # One-character conversion and okuri-ari conversion.
  'K a SPACE WAIT500 ENTER WAIT500'
  'K i e R u SPACE WAIT500 ENTER WAIT500'
  # DDSKK q conversion commits katakana without changing the base mode.
  'K a n a Q'
  # Candidate 5, learning, then local two-step Ctrl+G.
  'K a n a SPACE WAIT500 SPACE SPACE SPACE SPACE ENTER WAIT500'
  'K a n a SPACE WAIT500 CTRLG CTRLG'
  # Digits/symbols plus application-owned navigation and Ctrl shortcuts.
  '0 1 2 3 4 5 6 7 8 9 S1 S2 S3 S4 S5 S6 S7 S8 S9'
  'LEFT RIGHT CTRLC CTRLZ CTRLW CTRLS CTRLA'
  # Missing candidate -> registration; confirm exactly once.
  'P a p a p a SPACE WAIT500 t e s u t o ENTER WAIT500'
  # Direct katakana, wide Latin, F7/F6 and direct Latin modes.
  'q k a q L a S1 SPACE CTRLJ K a n a F7 F6 CTRLG l a CTRLJ'
) -join ' '

$savedDll = $env:DDSKK_HARNESS_DLL_PATH
$savedDictionaries = $env:DDSKK_DICTIONARY_FILES
$savedHost = $env:DDSKK_SKKSERV_HOST
$savedPort = $env:DDSKK_SKKSERV_PORT
$savedEnabled = $env:DDSKK_SKKSERV_ENABLE
try {
  $env:DDSKK_HARNESS_DLL_PATH = [IO.Path]::GetFullPath($DllPath)
  $env:DDSKK_DICTIONARY_FILES = [IO.Path]::GetFullPath($fixture)
  $env:DDSKK_SKKSERV_HOST = '127.0.0.1'
  $env:DDSKK_SKKSERV_PORT = '9'
  $env:DDSKK_SKKSERV_ENABLE = '0'
  $lines = @(& powershell -ExecutionPolicy Bypass -File $harness `
      -Script $script -EngineHostPath $hostExe -RepositoryPath $root `
      -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "run-harness failed with exit code $LASTEXITCODE"
  }
} finally {
  if ($null -eq $savedDll) { Remove-Item Env:DDSKK_HARNESS_DLL_PATH -ErrorAction SilentlyContinue } else { $env:DDSKK_HARNESS_DLL_PATH = $savedDll }
  if ($null -eq $savedDictionaries) { Remove-Item Env:DDSKK_DICTIONARY_FILES -ErrorAction SilentlyContinue } else { $env:DDSKK_DICTIONARY_FILES = $savedDictionaries }
  if ($null -eq $savedHost) { Remove-Item Env:DDSKK_SKKSERV_HOST -ErrorAction SilentlyContinue } else { $env:DDSKK_SKKSERV_HOST = $savedHost }
  if ($null -eq $savedPort) { Remove-Item Env:DDSKK_SKKSERV_PORT -ErrorAction SilentlyContinue } else { $env:DDSKK_SKKSERV_PORT = $savedPort }
  if ($null -eq $savedEnabled) { Remove-Item Env:DDSKK_SKKSERV_ENABLE -ErrorAction SilentlyContinue } else { $env:DDSKK_SKKSERV_ENABLE = $savedEnabled }
}

$script:behaviorText = $lines -join "`n"
function Require([string]$pattern, [string]$label) {
  if ($script:behaviorText -notmatch $pattern) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "DDSKK behavior failed: $label"
  }
}

# Keep regex literals ASCII-only: Windows PowerShell 5.1 decodes a BOM-less
# UTF-8 .ps1 as the active ANSI codepage. .NET regex expands \uXXXX itself.
Require 'AFTER WAIT500 BUF=\[\u868a\].*COMP=-' 'one-character conversion'
Require 'AFTER WAIT500 BUF=\[\u868a\u6d88\u3048\u308b\].*COMP=-' 'okuri-ari conversion'
Require 'AFTER Q BUF=\[\u868a\u6d88\u3048\u308b\u30ab\u30ca\].*COMP=-' 'Shift+Q katakana commit'
Require 'AFTER WAIT500 BUF=\[\u868a\u6d88\u3048\u308b\u30ab\u30ca\u4f73\u5948\].*COMP=-' 'candidate traversal beyond four'
Require 'AFTER WAIT500 BUF=\[\u868a\u6d88\u3048\u308b\u30ab\u30ca\u4f73\u5948\u25bc\u4f73\u5948\]' 'committed candidate learning'
Require 'AFTER CTRLG BUF=\[\u868a\u6d88\u3048\u308b\u30ab\u30ca\u4f73\u5948\u25bd\u304b\u306a\]' 'candidate cancellation restores reading'

foreach ($token in @('0','1','2','3','4','5','6','7','8','9',
                      'S1','S2','S3','S4','S5','S6','S7','S8','S9')) {
  Require ("KEYLAT token={0} .*claimed=1" -f $token) "claimed literal $token"
}
foreach ($token in @('LEFT','RIGHT','CTRLC','CTRLZ','CTRLW','CTRLS','CTRLA')) {
  Require ("KEYLAT token={0} .*claimed=0" -f $token) "application-owned $token"
}
Require 'AFTER WAIT500 BUF=\[[^\]]*\u3066\u3059\u3068\].*COMP=-' 'registration confirm'
if ($script:behaviorText -match '\u3066\u3059\u3068\u3066\u3059\u3068') { throw 'DDSKK behavior failed: registration duplicated text' }
Require 'AFTER a BUF=\[[^\]]*\u3066\u3059\u3068\u30ab\].*COMP=-' 'direct katakana mode'
Require 'AFTER CTRLJ BUF=\[[^\]]*\uff41\uff01\u3000\].*COMP=-' 'wide Latin mode'
Require 'AFTER F7 BUF=\[[^\]]*\u25bd\u30ab\u30ca\]' 'F7 katakana transliteration'
Require 'AFTER F6 BUF=\[[^\]]*\u25bd\u304b\u306a\]' 'F6 hiragana transliteration'
Require 'KEYLAT token=a .*claimed=0' 'direct Latin pass-through'

$ctrlG = @($lines | Where-Object { $_ -match '^KEYLAT token=CTRLG .*total_us=(\d+) ' } |
  ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
if ($ctrlG.Count -lt 2 -or ($ctrlG | Measure-Object -Maximum).Maximum -gt 20000) {
  throw "DDSKK behavior failed: Ctrl+G exceeded 20 ms ($($ctrlG -join ',') us)"
}

[pscustomobject]@{
  Result = 'PASS'
  CtrlGMaxMs = [Math]::Round((($ctrlG | Measure-Object -Maximum).Maximum / 1000.0), 3)
  Assertions = 43
}
