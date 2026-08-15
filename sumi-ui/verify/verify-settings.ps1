<#
.SYNOPSIS
  Phase 3 verification for sumi-ui/target/sumi-skk-ui.exe's settings I/O:
  runs the headless `--settings-selftest' entry point against a disposable
  registry key and asserts every check passed.

.DESCRIPTION
  Full GUI interaction (opening the settings window, clicking through its
  four tabs) is not required for this verification -- see the Phase 3
  task brief ("Full GUI interaction is not required; compile-clean +
  selftest PASS + the existing indicator verify still PASS is the bar").
  This script only drives the headless self-test path
  (indicator/settings.c's settings_selftest(), invoked via
  `sumi-skk-ui.exe --settings-selftest'), which exercises exactly the
  same settings_load()/settings_save() functions the settings window's
  Apply button and initial load use -- see main.c's on_apply_clicked()/
  on_activate().

  Safety: DDSKK_SETTINGS_KEY is ALWAYS set to a disposable key before
  invoking --settings-selftest, both because this script sets it and
  because settings_selftest() itself refuses to run at all (prints an
  error, exits 1) unless that variable is non-empty -- a second,
  independent guard against ever mutating the real
  HKCU\Software\NativeIME the production DLL reads. This script also
  explicitly deletes the disposable key afterwards as a belt-and-
  suspenders cleanup, even though settings_selftest()'s own last step
  already does (see settings.c's settings_selftest(): step 3 deletes the
  key, then an unconditional settings_delete_all() runs again right
  before the final SELFTEST-PASS/FAIL line) -- so by the time this
  script's own cleanup runs, the key should already be gone; the
  Remove-Item below is idempotent either way.

.PARAMETER IndicatorExe
  Path to sumi-skk-ui.exe. Defaults to sumi-ui/target/sumi-skk-ui.exe
  next to this script.

.PARAMETER SettingsKey
  HKCU-relative disposable registry key to use. Defaults to
  "Software\NativeIME-PhaseThreeTest".

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File sumi-ui\verify\verify-settings.ps1
#>
[CmdletBinding()]
param(
  [string]$IndicatorExe = "",
  [string]$SettingsKey = "Software\NativeIME-PhaseThreeTest"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($IndicatorExe)) {
  $IndicatorExe = Join-Path $PSScriptRoot "..\target\sumi-skk-ui.exe"
}
$IndicatorExe = [System.IO.Path]::GetFullPath($IndicatorExe)

if (-not (Test-Path -LiteralPath $IndicatorExe)) {
  Write-Error "sumi-skk-ui.exe not found at $IndicatorExe -- run 'emacs -Q --batch -l build.el' first."
  exit 1
}

$regPath = "HKCU:\$SettingsKey"

function Remove-DisposableKey {
  if (Test-Path -LiteralPath $regPath) {
    Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Belt-and-suspenders: never start this test with a stale key from a
# previous interrupted run sitting under the same disposable name.
Remove-DisposableKey

$exitCode = 1
$runId = [guid]::NewGuid().ToString("N").Substring(0, 10)
$stdoutLog = Join-Path $env:TEMP "sumi-skk-ui-selftest-$runId.out.log"
$stderrLog = Join-Path $env:TEMP "sumi-skk-ui-selftest-$runId.err.log"
try {
  Write-Host "verify-settings: DDSKK_SETTINGS_KEY=$SettingsKey"
  $env:DDSKK_SETTINGS_KEY = $SettingsKey

  # sumi-skk-ui.exe is linked -mwindows (no console subsystem, see
  # build.el's sumi-ui-link docstring) so its CRT stdio only goes
  # anywhere if the parent explicitly supplies redirected handles.
  # Start-Process -RedirectStandardOutput/-RedirectStandardError does
  # that reliably (proven in Phase 2's verify.ps1); plain `& exe 2>&1`
  # pipeline capture does not -- confirmed empirically here: it silently
  # returns $null for this exact binary instead of the selftest's PASS/
  # FAIL lines, even though the process itself runs and exits normally.
  $proc = Start-Process -FilePath $IndicatorExe -ArgumentList @("--settings-selftest") `
    -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog `
    -WindowStyle Hidden -PassThru -Wait
  Write-Host "verify-settings: process exit code = $($proc.ExitCode)"

  $output = @(if (Test-Path $stdoutLog) { Get-Content $stdoutLog })
  $stderrOutput = @(if (Test-Path $stderrLog) { Get-Content $stderrLog })
  $output | ForEach-Object { Write-Host "  $_" }
  if ($stderrOutput.Count -gt 0) {
    Write-Host "verify-settings: stderr:"
    $stderrOutput | ForEach-Object { Write-Host "  $_" }
  }

  $pass = ($output -match '^PASS ').Count
  $fail = ($output -match '^FAIL ').Count
  $overall = $output -match '^SELFTEST-(PASS|FAIL)'

  Write-Host "verify-settings: $pass PASS lines, $fail FAIL lines"

  if ($fail -eq 0 -and $pass -gt 0 -and $overall -match 'SELFTEST-PASS') {
    Write-Host "verify-settings: PASS -- settings_selftest reported SELFTEST-PASS with no FAIL lines."
    $exitCode = 0
  } else {
    Write-Host "verify-settings: FAIL -- expected SELFTEST-PASS with zero FAIL lines."
    $exitCode = 1
  }

  if (Test-Path -LiteralPath $regPath) {
    Write-Host "verify-settings: FAIL -- disposable key $regPath still exists after selftest (should self-clean)."
    $exitCode = 1
  } else {
    Write-Host "verify-settings: disposable key $regPath confirmed absent after selftest."
  }
} finally {
  Remove-Item Env:\DDSKK_SETTINGS_KEY -ErrorAction SilentlyContinue
  # Cleanup, independent of whether the selftest itself already removed
  # the key (see script-level comment above) and independent of pass/fail.
  Remove-DisposableKey
  Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
}

exit $exitCode
