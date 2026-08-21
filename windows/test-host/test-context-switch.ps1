[CmdletBinding()]
param(
  [int]$ColdLoadSleepSec = 12,
  [string]$DllPath = ''
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$harness = Join-Path $PSScriptRoot 'run-harness.ps1'
$hostExe = Join-Path $root 'windows\build\Release\ddskk-engine-host.exe'
if (-not $DllPath) { $DllPath = Join-Path $root 'windows\build\Release\ddskk-ime.dll' }

# Begin a provider conversion in context 1, switch before its reply, type in
# context 2, then return. The old reading is settled without its SKK marker;
# the stale provider reply cannot touch either document, and each context's
# later text remains independent.
$script = 'K a SPACE CTX2 n CHECK1 WAIT700 CHECK1 a CHECK1 CTX1 a CHECK1 CHECK2'
$savedDll = $env:DDSKK_HARNESS_DLL_PATH
try {
  $env:DDSKK_HARNESS_DLL_PATH = [IO.Path]::GetFullPath($DllPath)
  $lines = @(& powershell -ExecutionPolicy Bypass -File $harness `
    -Script $script -EngineHostPath $hostExe -RepositoryPath $root `
    -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
  if ($LASTEXITCODE -ne 0) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "run-harness failed with exit code $LASTEXITCODE"
  }
} finally {
  if ($null -eq $savedDll) {
    Remove-Item Env:DDSKK_HARNESS_DLL_PATH -ErrorAction SilentlyContinue
  } else { $env:DDSKK_HARNESS_DLL_PATH = $savedDll }
}

$text = $lines -join "`n"
$assertions = 0
function Require([string]$Pattern, [string]$Label) {
  if ($script:text -notmatch $Pattern) {
    $lines | ForEach-Object { Write-Host $_ }
    throw "context-switch behavior failed: $Label"
  }
  $script:assertions++
}

Require 'AFTER CHECK1 BUF=\[\u304b\].*COMP=-' 'old preedit settled as plain kana'
Require 'AFTER WAIT700 BUF=\[n\].*COMP=0,1' 'stale provider reply ignored in new context'
Require 'AFTER CHECK1 BUF=\[\u304b\u3042\].*COMP=-' 'returning context accepts fresh input'
Require 'AFTER CHECK2 BUF=\[\u306a\].*COMP=-' 'second context remains independent'
Require 'FINAL BUF_LEN=2 BUF_FNV=d2fa5c0787dcc678' 'first document exact final content'
if ($text -match 'AFTER CHECK[12] BUF=\[[^\]]*[\u25bd\u25bc]') {
  throw 'context-switch behavior failed: SKK UI marker leaked into settled text'
}
$assertions++

[pscustomobject]@{ Result = 'PASS'; Assertions = $assertions }
