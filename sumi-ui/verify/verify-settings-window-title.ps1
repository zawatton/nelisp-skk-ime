<#
.SYNOPSIS
  Checks that the DLL and the settings UI agree on the settings window
  title, which is how the DLL finds an already-open window.

.DESCRIPTION
  TextService::ShowSettings() calls FindWindowW with a literal title to
  decide whether to focus an existing settings window or start another
  process. sumi-ui sets that title with gtk_window_set_title. Nothing
  links the two: if either string changes, FindWindowW simply stops
  matching and the IME silently goes back to spawning a new window on
  every click -- the exact bug the lookup was added to fix, returning
  with no error anywhere.

  So this compares them. The UI spells the title as C hex escapes
  ("SKK \xe8\xa8\xad\xe5\xae\x9a"), which are decoded here as UTF-8
  before the comparison.

  Exits 0 when they agree, 1 when they do not.
#>
[CmdletBinding()]
param([string]$Root = '')
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty while parameter defaults are bound, so the repo
# root is resolved here instead.
if (-not $Root) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

function Expand-CEscapes([string]$literal) {
  $bytes = New-Object System.Collections.Generic.List[byte]
  $i = 0
  while ($i -lt $literal.Length) {
    if ($literal[$i] -eq '\' -and $i + 3 -lt $literal.Length -and $literal[$i+1] -eq 'x') {
      $bytes.Add([Convert]::ToByte($literal.Substring($i+2,2),16)); $i += 4
    } else {
      $bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes([string]$literal[$i])); $i += 1
    }
  }
  return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

$dllSrc = Join-Path $Root 'windows/src/text_service.cpp'
$uiSrc  = Join-Path $Root 'sumi-ui/indicator/main.c'

$dllLine = Select-String -Path $dllSrc -Pattern 'kSettingsWindowTitle\[\]\s*=\s*L"([^"]*)"'
if (-not $dllLine) { Write-Host "FAIL: kSettingsWindowTitle not found in $dllSrc"; exit 1 }
$dllTitle = $dllLine.Matches[0].Groups[1].Value

$uiLine = Select-String -Path $uiSrc -Pattern 'gtk_window_set_title\(GTK_WINDOW\(window\),\s*"([^"]*)"'
if (-not $uiLine) { Write-Host "FAIL: settings gtk_window_set_title not found in $uiSrc"; exit 1 }
$uiTitle = Expand-CEscapes $uiLine.Matches[0].Groups[1].Value

Write-Host ("DLL : [{0}]" -f $dllTitle)
Write-Host ("UI  : [{0}]" -f $uiTitle)
# The class matters as much as the title: FindWindowW with a null class
# does not match a GTK4 toplevel even when the title is byte-identical,
# so the DLL has to pass one and it has to be the class GTK4 actually
# uses. Checked against a live window rather than assumed.
$dllClass = Select-String -Path $dllSrc -Pattern 'kGtkToplevelClass\[\]\s*=\s*L"([^"]*)"'
if (-not $dllClass) { Write-Host 'FAIL: kGtkToplevelClass not found'; exit 1 }
$cls = $dllClass.Matches[0].Groups[1].Value
Write-Host ("class: [{0}]" -f $cls)
if ($cls -cne 'gdkSurfaceToplevel') {
  Write-Host "FAIL: unexpected toplevel class -- verify against a live GTK4 window"
  exit 1
}
if ($dllTitle -ceq $uiTitle) { Write-Host 'PASS: titles agree'; exit 0 }
Write-Host 'FAIL: titles differ -- FindWindowW would stop matching and the'
Write-Host '      IME would spawn a new settings window on every click.'
exit 1
