<#
.SYNOPSIS
  Phase 2 verification for sumi-ui/target/sumi-skk-ui.exe: drives real
  mode transitions through the shared engine session and asserts the
  indicator's own STATUS-polling stdout log observed them in order.

.DESCRIPTION
  Mirrors windows/test-host/run-harness.ps1's private-pipe pattern (own
  disposable pipe, own disposable user jisyo, only ever touches
  processes this script itself started) but talks to the engine host
  directly -- this indicator never goes through tsf-host.exe/TSF, so
  there is nothing to drive keystrokes through except the pipe itself.

  1. Starts ddskk-engine-host.exe (EngineHost/EngineExe/Repository,
     same argv shape as run-harness.ps1: ENGINE_EXE [REPOSITORY]) on a
     fresh named pipe + temp jisyo.
  2. Starts sumi-skk-ui.exe pointed at that same pipe via
     DDSKK_PIPE_NAME, with its stdout redirected to a log file --
     see main.c's app_log_transition(), which prints "MODE <name>"
     every time a STATUS poll observes a *changed* mode.
  3. As a second, independent client of the same shared engine session
     (docs/design/sumi-indicator-settings.md: "The engine session is
     shared by all clients, so the UI app can both observe and drive
     the input mode over the same pipe the TSF DLL uses"), sends a
     scripted KEY/CONTROL sequence with pauses long enough for the
     indicator's 500 ms poll to observe each resulting state.
  4. Stops the indicator (Stop-Process by pid) and reads its stdout
     log; stops the host (SHUTDOWN over the pipe, then a PID-scoped
     force-kill fallback, exactly like run-harness.ps1).
  5. Asserts the expected mode sequence appears, in order, among the
     logged "MODE <name>" lines.

  The exact transition sequence below (hiragana -> katakana -> latin ->
  hiragana -> wide-latin -> hiragana -> preedit -> hiragana) was first
  confirmed by probing the real engine directly over a private pipe
  before this script was written -- see the KEY codes' provenance in
  docs/design/sumi-indicator-settings.md's "Mode switching from the
  indicator" table (113="q", 108="l", 76="L") plus KEY 65 ("A", an
  uppercase romaji letter, which is what actually starts a DDSKK
  conversion/preedit in skk-ime-session.el -- not part of that table,
  added here specifically to exercise the preedit/previous-base code
  path in mode-logic.el's skkui_color_for/skkui_label_for).

.PARAMETER IndicatorExe
  Path to sumi-skk-ui.exe. Defaults to sumi-ui/target/sumi-skk-ui.exe
  next to this script.

.PARAMETER EngineHost
  Path to ddskk-engine-host.exe.

.PARAMETER EngineExe
  Path to the NeLisp engine executable (nelisp.exe).

.PARAMETER Repository
  Repository argument passed to the engine host (this checkout).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File sumi-ui\verify\verify.ps1
#>
[CmdletBinding()]
param(
  [string]$IndicatorExe = "",
  [string]$EngineHost = "$env:LOCALAPPDATA\DDSKK\20260815-120454\ddskk-engine-host.exe",
  [string]$EngineExe = "C:\Users\kuroz\Cowork\Notes\dev\nelisp\target\nelisp.exe",
  [string]$Repository = "",
  [int]$ColdLoadSleepSec = 8,
  [int]$PipeWaitTimeoutSec = 30,
  [int]$StepPauseMs = 800
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Repository)) {
  $Repository = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}
if ([string]::IsNullOrWhiteSpace($IndicatorExe)) {
  $IndicatorExe = Join-Path $PSScriptRoot "..\target\sumi-skk-ui.exe"
}
$IndicatorExe = [System.IO.Path]::GetFullPath($IndicatorExe)

if (-not (Test-Path -LiteralPath $EngineHost)) { Write-Error "EngineHost not found: $EngineHost"; exit 1 }
if (-not (Test-Path -LiteralPath $EngineExe)) { Write-Error "EngineExe not found: $EngineExe"; exit 1 }
if (-not (Test-Path -LiteralPath $IndicatorExe)) {
  Write-Error "sumi-skk-ui.exe not found at $IndicatorExe -- run 'emacs -Q --batch -l build.el' first."
  exit 1
}

function Wait-ForNamedPipe {
  param([Parameter(Mandatory)][string]$PipeFullName, [Parameter(Mandatory)][int]$TimeoutSec)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $PipeFullName) { return $true }
    Start-Sleep -Milliseconds 150
  }
  return $false
}

function Send-EngineRequest {
  param([Parameter(Mandatory)][string]$PipeShortName, [Parameter(Mandatory)][string]$Request)
  $client = New-Object System.IO.Pipes.NamedPipeClientStream(
    ".", $PipeShortName, [System.IO.Pipes.PipeDirection]::InOut)
  $client.Connect(5000)
  $client.ReadMode = [System.IO.Pipes.PipeTransmissionMode]::Message
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($Request)
  $client.Write($bytes, 0, $bytes.Length)
  $client.Flush()
  $buf = New-Object byte[] 8192
  $n = $client.Read($buf, 0, $buf.Length)
  $client.Dispose()
  return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
}

function Send-ShutdownRequest {
  param([Parameter(Mandatory)][string]$PipeShortName)
  try {
    $client = New-Object System.IO.Pipes.NamedPipeClientStream(
      ".", $PipeShortName, [System.IO.Pipes.PipeDirection]::InOut)
    $client.Connect(500)
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("SHUTDOWN")
    $client.Write($bytes, 0, $bytes.Length)
    $client.Flush()
    Start-Sleep -Milliseconds 300
    $client.Dispose()
    return $true
  } catch { return $false }
}

# Subsequence check: every element of Expected must appear in Observed,
# in the same relative order (extra/duplicate Observed entries in
# between are fine -- e.g. a re-observed unchanged mode).
function Assert-Subsequence {
  param([Parameter(Mandatory)][string[]]$Expected, [Parameter(Mandatory)][string[]]$Observed)
  $i = 0
  foreach ($item in $Observed) {
    if ($i -ge $Expected.Count) { break }
    if ($item -eq $Expected[$i]) { $i++ }
  }
  return $i -eq $Expected.Count
}

$runId = [guid]::NewGuid().ToString("N").Substring(0, 10)
$pipeShortName = "ddskk-verify-$runId"
$pipeFullName = "\\.\pipe\$pipeShortName"
$tempJisyo = Join-Path $env:TEMP "ddskk-verify-jisyo-$runId.jisyo"
$indicatorOut = Join-Path $env:TEMP "sumi-skk-ui-verify-$runId.out.log"
$indicatorErr = Join-Path $env:TEMP "sumi-skk-ui-verify-$runId.err.log"

$env:DDSKK_PIPE_NAME = $pipeFullName
$env:DDSKK_USER_JISYO = $tempJisyo

Write-Host "verify: pipe=$pipeFullName jisyo=$tempJisyo"
Write-Host "verify: starting engine host: [$EngineHost] [$EngineExe] [$Repository]"

$hostProcess = $null
$indicatorProcess = $null
$exitCode = 1

try {
  $hostProcess = Start-Process -FilePath $EngineHost -ArgumentList @($EngineExe, $Repository) `
    -WindowStyle Hidden -PassThru

  Write-Host "verify: waiting up to ${PipeWaitTimeoutSec}s for the pipe..."
  if (-not (Wait-ForNamedPipe -PipeFullName $pipeFullName -TimeoutSec $PipeWaitTimeoutSec)) {
    Write-Error "Timed out waiting for $pipeFullName (host pid=$($hostProcess.Id))."
    exit 1
  }

  Write-Host "verify: pipe up; sleeping ${ColdLoadSleepSec}s for engine cold load..."
  Start-Sleep -Seconds $ColdLoadSleepSec

  Write-Host "verify: starting indicator: $IndicatorExe"
  $indicatorProcess = Start-Process -FilePath $IndicatorExe `
    -RedirectStandardOutput $indicatorOut -RedirectStandardError $indicatorErr `
    -WindowStyle Hidden -PassThru
  # Let the window come up and at least one 500 ms STATUS poll land before
  # driving any transitions -- otherwise the very first poll can race the
  # first driven KEY and the initial "MODE hiragana" observation is lost
  # (not an indicator bug: it always reports whatever the engine's actual
  # current state is at poll time; this is purely pacing this script's own
  # driver against that 500 ms cadence with a comfortable margin). Phase 3
  # added a settings_load() registry read (~17 values) to on_activate()
  # before the first poll is scheduled, so this needs more headroom than
  # Phase 2's original 2000 ms -- bumped to 3500 ms after observing an
  # occasional miss of the initial "hiragana" line at 2000 ms following
  # the Phase 3 settings-window changes.
  Start-Sleep -Milliseconds 3500

  Write-Host "verify: driving mode transitions as a second pipe client..."
  # hiragana (initial) -> katakana -> latin -> hiragana -> wide-latin ->
  # hiragana -> preedit -> hiragana. See the script-level comment above
  # for how this exact sequence was chosen/confirmed.
  $steps = @(
    @{ Req = "KEY 113`n"; Note = "q: hiragana -> katakana" },
    @{ Req = "KEY 108`n"; Note = "l: katakana -> latin" },
    @{ Req = "CONTROL CANCEL`n"; Note = "cancel: latin -> hiragana" },
    @{ Req = "KEY 76`n"; Note = "L: hiragana -> wide-latin" },
    @{ Req = "CONTROL CANCEL`n"; Note = "cancel: wide-latin -> hiragana" },
    @{ Req = "KEY 65`n"; Note = "A: hiragana -> preedit" },
    @{ Req = "CONTROL CANCEL`n"; Note = "cancel: preedit -> hiragana" }
  )
  foreach ($step in $steps) {
    $reply = Send-EngineRequest -PipeShortName $pipeShortName -Request $step.Req
    Write-Host ("verify:   {0,-32} -> {1}" -f $step.Note, $reply.Trim())
    Start-Sleep -Milliseconds $StepPauseMs
  }

  Write-Host "verify: stopping indicator and reading its log..."
  if (-not $indicatorProcess.HasExited) {
    Stop-Process -Id $indicatorProcess.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 300

  $observedLines = @(if (Test-Path $indicatorOut) { Get-Content $indicatorOut })
  Write-Host "verify: indicator stdout:"
  $observedLines | ForEach-Object { Write-Host "  $_" }
  Write-Host "verify: indicator stderr:"
  if (Test-Path $indicatorErr) { Get-Content $indicatorErr | ForEach-Object { Write-Host "  $_" } }

  # @(...) coerces to an array even when 0 or 1 lines match -- PowerShell
  # unwraps a single-element pipeline result to a bare scalar (or $null
  # for zero elements), which would otherwise fail Assert-Subsequence's
  # [string[]] parameter bind.
  $observedModes = @($observedLines | Where-Object { $_ -match '^MODE (\S+)$' } |
    ForEach-Object { $Matches[1] })
  $expectedModes = @("hiragana", "katakana", "latin", "hiragana", "wide-latin", "hiragana", "preedit", "hiragana")

  Write-Host ("verify: expected subsequence: {0}" -f ($expectedModes -join " -> "))
  Write-Host ("verify: observed sequence:    {0}" -f ($observedModes -join " -> "))

  if (Assert-Subsequence -Expected $expectedModes -Observed $observedModes) {
    Write-Host "verify: PASS -- expected mode sequence observed in order."
    $exitCode = 0
  } else {
    Write-Host "verify: FAIL -- expected mode sequence not found as an ordered subsequence."
    $exitCode = 1
  }
} finally {
  if ($indicatorProcess -ne $null) {
    try { if (-not $indicatorProcess.HasExited) { Stop-Process -Id $indicatorProcess.Id -Force -ErrorAction SilentlyContinue } } catch {}
  }
  if ($hostProcess -ne $null) {
    $stillRunning = $false
    try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    if ($stillRunning) {
      Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
      Start-Sleep -Milliseconds 300
      try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    }
    if ($stillRunning) {
      Write-Host "verify: force-killing host pid=$($hostProcess.Id)."
      Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path -LiteralPath $tempJisyo) { Remove-Item -LiteralPath $tempJisyo -Force -ErrorAction SilentlyContinue }
}

exit $exitCode
