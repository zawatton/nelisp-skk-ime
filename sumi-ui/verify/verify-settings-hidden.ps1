param([string]$IndicatorExe = (Join-Path $PSScriptRoot '../target/sumi-skk-ui.exe'))
$ErrorActionPreference = 'Stop'
$id = [guid]::NewGuid().ToString('N')
$dir = Join-Path $env:TEMP "sumi-window-$id"
$key = "Software\NativeIME-Tests\SU1-$id"
$reg = "HKCU:\$key"
$oldKey = $env:NATIVEIME_REGISTRY_KEY
$oldRules = $env:NELISP_IME_INPUT_RULES
$oldMap = $env:NELISP_IME_KEYMAP_FILE
$proc = $null
try {
  New-Item -ItemType Directory -Path $dir | Out-Null
  $env:NATIVEIME_REGISTRY_KEY = $key
  $env:NELISP_IME_INPUT_RULES = Join-Path $dir 'input-rules.conf'
  $env:NELISP_IME_KEYMAP_FILE = Join-Path $dir 'keymap.conf'
  [IO.File]::WriteAllText($env:NELISP_IME_INPUT_RULES, "width = zenkaku`nauto-pair = no`n")
  [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE, "enabled = yes`nlayout = US`n")
  New-Item -Path "$reg\Keymap" -Force | Out-Null
  New-ItemProperty -Path "$reg\Keymap" -Name Status -Value 'error' -PropertyType String | Out-Null
  New-ItemProperty -Path "$reg\Keymap" -Name Errors -Value @('line 3: unknown option', 'line 4: invalid key') -PropertyType MultiString | Out-Null
  $out = Join-Path $dir 'stdout.log'
  $err = Join-Path $dir 'stderr.log'
  $proc = Start-Process -FilePath ([IO.Path]::GetFullPath($IndicatorExe)) -ArgumentList '--settings-window-selftest' -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if (-not $proc.WaitForExit(30000)) { throw 'hidden window selftest timed out' }
  $proc.Refresh()
  $lines = @(Get-Content -LiteralPath $out)
  $lines | ForEach-Object { Write-Host $_ }
  Get-Content -LiteralPath $err | ForEach-Object { Write-Host $_ }
  if ($proc.ExitCode -ne 0 -or -not ($lines -contains 'PASS hidden-settings-six-tabs-and-file-controls')) { throw 'hidden settings controls failed' }
  if (-not ($lines -contains 'Status: error') -or -not ($lines -contains 'Errors: line 3: unknown option') -or -not ($lines -contains 'line 4: invalid key')) { throw 'read-only remapper status failed' }
  Write-Host 'PASS read-only-status-and-multisz-errors'
  foreach ($check in @('keymap-page-button','rules-page-button','initial-widget-values','engine-page-switch','apply-all-tabs-and-range-validation','apply-failure-status','close-during-restart')) {
    if (-not ($lines -contains "PASS hidden-settings-$check")) { throw "hidden settings $check failed" }
  }
  Write-Host 'verify-settings-hidden: 9 PASS, 0 FAIL; exit 0'
} finally {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  if (Test-Path -LiteralPath $reg) { Remove-Item -LiteralPath $reg -Recurse -Force }
  foreach ($name in @('input-rules.conf','keymap.conf','stdout.log','stderr.log')) {
    Remove-Item -LiteralPath (Join-Path $dir $name) -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
  $env:NATIVEIME_REGISTRY_KEY = $oldKey
  $env:NELISP_IME_INPUT_RULES = $oldRules
  $env:NELISP_IME_KEYMAP_FILE = $oldMap
}
