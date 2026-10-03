<#
.SYNOPSIS
  Drives tsf-host.exe against the real ddskk-ime engine on a private,
  disposable named pipe -- no shared state with any live Emacs/anvil
  session or interactively-registered engine host.

.DESCRIPTION
  1. Requires explicit EngineHost / EngineExecutable / Repository paths,
     and creates a disposable Software\NativeIME-test-<uuid> key.
  2. Generates a unique named-pipe name and points DDSKK_PIPE_NAME at it,
     and DDSKK_USER_JISYO at a fresh temp file, so this run never touches
     anyone else's dictionary or collides with another running host.
  3. Starts ddskk-engine-host.exe with those paths (it inherits both env
     vars) and waits for the pipe to come up.
  4. The engine's cold load measures ~3.4 s *after* the host (and its
     pipe) are already up, so this sleeps a further 6 s before launching
     tsf-host.exe -- otherwise the very first scripted keys would race the
     cold load and the test would be flaky for reasons that have nothing
     to do with the IME itself.
  5. Runs tsf-host.exe with the script argument, letting its stdout (the
     "AFTER ..." / "HR ..." / "COMPOSITION ..." lines) flow straight
     through to this script's own stdout for the caller to read.
  6. Cleans up: tries a graceful SHUTDOWN over the pipe first (the host
     already knows how to tear down the engine child it spawned that
     way), then force-kills *only* that host process id as a fallback.
     Never touches any other process. Deletes the temp jisyo.

.PARAMETER Script
  The space-separated tsf-host.exe key script (see tsf_host.cpp for the
  token grammar). Omit to just smoke-test host+engine bring-up.

.PARAMETER TsfHostExe
  Path to tsf-host.exe. Defaults to the Release build next to this
  script's own build tree (windows/build/<Configuration>/tsf-host.exe).

.PARAMETER Configuration
  Build configuration folder name used to resolve the default
  -TsfHostExe path. Ignored if -TsfHostExe is given explicitly.

.PARAMETER ColdLoadSleepSec
  Extra sleep after the pipe appears, to clear the engine's cold load.

.PARAMETER PipeWaitTimeoutSec
  How long to wait for the engine host's named pipe to appear.

.PARAMETER TsfHostTimeoutSec
  How long to wait for tsf-host.exe to finish before it is force-killed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File windows\test-host\run-harness.ps1 `
    -Script "a s a CTRLJ"
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Script = "",

  [string]$TsfHostExe = "",
  [string]$DllPath = "",

  # Required build-under-test paths; no installed registry defaults.
  [string]$EngineHostPath = "",
  [string]$EngineExecutablePath = "",
  [string]$RepositoryPath = "",

  [string]$Configuration = "Release",

  # Engine cold load has been measured anywhere from 3.4s (quiet machine)
  # to ~12s (loaded machine); a 6s default let the first scripted keys race
  # the load and get swallowed, which read as false engine regressions.
  [int]$ColdLoadSleepSec = 12,

  [int]$PipeWaitTimeoutSec = 30,

  [int]$TsfHostTimeoutSec = 60
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Wait-ForNamedPipe {
  param(
    [Parameter(Mandatory)] [string]$PipeFullName,
    [Parameter(Mandatory)] [int]$TimeoutSec
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $PipeFullName) { return $true }
    Start-Sleep -Milliseconds 150
  }
  return $false
}

function Send-ShutdownRequest {
  # Best-effort graceful stop: writes the same "SHUTDOWN" request the
  # engine host's own E2E test uses. This only ever talks to the host
  # process over its pipe -- it never touches the engine child directly;
  # the host does that internally once it sees this request.
  param([Parameter(Mandatory)] [string]$PipeShortName)
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
  } catch {
    return $false
  }
}

if ([string]::IsNullOrWhiteSpace($TsfHostExe)) {
  $TsfHostExe = Join-Path $PSScriptRoot "..\build\$Configuration\tsf-host.exe"
}
$TsfHostExe = [System.IO.Path]::GetFullPath($TsfHostExe)

$runId = [guid]::NewGuid().ToString("N").Substring(0, 12)
$registryKey = "Software\NativeIME-test-$runId"
$regPath = "HKCU:\$registryKey"
if ([string]::IsNullOrWhiteSpace($EngineHostPath) -or
    [string]::IsNullOrWhiteSpace($EngineExecutablePath) -or
    [string]::IsNullOrWhiteSpace($RepositoryPath)) {
  throw 'Private harness requires EngineHostPath, EngineExecutablePath and RepositoryPath.'
}
if (-not [string]::IsNullOrWhiteSpace($EngineHostPath)) {
  $engineHost = [IO.Path]::GetFullPath($EngineHostPath)
}
if (-not [string]::IsNullOrWhiteSpace($EngineExecutablePath)) {
  $engineExecutable = [IO.Path]::GetFullPath($EngineExecutablePath)
}
if (-not [string]::IsNullOrWhiteSpace($RepositoryPath)) {
  $repository = [IO.Path]::GetFullPath($RepositoryPath)
}

if ([string]::IsNullOrWhiteSpace($engineHost)) {
  Write-Error "$regPath has no EngineHost value."
  exit 1
}
if ([string]::IsNullOrWhiteSpace($engineExecutable)) {
  Write-Error "$regPath has no EngineExecutable value."
  exit 1
}
if (-not (Test-Path -LiteralPath $TsfHostExe)) {
  Write-Error "tsf-host.exe not found at $TsfHostExe -- build the tsf-host CMake target first."
  exit 1
}
if (-not $DllPath) {
  $DllPath = if ($env:DDSKK_HARNESS_DLL_PATH) { $env:DDSKK_HARNESS_DLL_PATH }
    else { Join-Path ([IO.Path]::GetDirectoryName($TsfHostExe)) 'ddskk-ime.dll' }
}
$DllPath = [IO.Path]::GetFullPath($DllPath)
if (-not (Test-Path -LiteralPath $DllPath)) { throw "Private test DLL not found: $DllPath" }

$pipeShortName = "ddskk-test-$runId"
$pipeFullName = "\\.\pipe\$pipeShortName"
$tempJisyo = Join-Path $env:TEMP "ddskk-test-jisyo-$runId.jisyo"

# Set before starting the host: System.Diagnostics.Process inherits the
# current process's environment block at start time, same as the
# CreateProcessW(..., lpEnvironment=nullptr, ...) convention the host and
# its own E2E test already rely on (see host/main.cpp PipeName()).
$savedEnvironment = @{}
foreach ($name in @('DDSKK_PIPE_NAME','DDSKK_USER_JISYO','NATIVEIME_REGISTRY_KEY',
    'LOCALAPPDATA','NELISP_IME_ENGINE','NATIVEIME_TEST_HOST_PID','NATIVEIME_TEST_ENGINE_NAME','DDSKK_HARNESS_DLL_PATH')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$hostProcess = $null
$exitCode = 1
$savedDisableHostSpawn = $env:NELISP_IME_DISABLE_HOST_SPAWN
try {
$env:DDSKK_HARNESS_DLL_PATH = $DllPath
$env:DDSKK_PIPE_NAME = $pipeFullName
$env:DDSKK_USER_JISYO = $tempJisyo
$env:NATIVEIME_REGISTRY_KEY = $registryKey
# Seed the private settings, including the host's dictionary bridge, even
# when every executable path is supplied explicitly.
New-Item -Path $regPath -Force | Out-Null
$initialEngine = if ($env:NELISP_IME_ENGINE) { $env:NELISP_IME_ENGINE } else { 'ddskk' }
foreach ($entry in @{
  EngineHost=$engineHost; EngineExecutable=$engineExecutable; Repository=$repository
  Engine=$initialEngine; UserJisyoPath=$tempJisyo
  DictionaryFiles=(Join-Path $PSScriptRoot 'data\behavior-jisyo.utf8')
}.GetEnumerator()) {
  New-ItemProperty -Path $regPath -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name SkkServEnable -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $regPath -Name InitialKanaMode -Value 1 -PropertyType DWord -Force | Out-Null
# Logs and user data must also stay out of the installed IME's directory.
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetDirectoryName($TsfHostExe)) "harness-$runId"
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$hostOutput = Join-Path $env:LOCALAPPDATA 'host.stdout.log'
$hostError = Join-Path $env:LOCALAPPDATA 'host.stderr.log'
$tsfOutput = Join-Path $env:LOCALAPPDATA 'tsf.stdout.log'
$tsfError = Join-Path $env:LOCALAPPDATA 'tsf.stderr.log'
# The registry is authoritative for live-switch tests, so do not pin the DLL.
Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue
Remove-Item Env:NELISP_IME_DISABLE_HOST_SPAWN -ErrorAction SilentlyContinue

Write-Host "run-harness: pipe=$pipeFullName jisyo=$tempJisyo"
Write-Host "run-harness: starting engine host: [$engineHost] [$engineExecutable] [$repository]"

$hostArgs = @("`"$engineExecutable`"")
if (-not [string]::IsNullOrWhiteSpace($repository)) { $hostArgs += "`"$repository`"" }

  $hostProcess = Start-Process -FilePath $engineHost -ArgumentList $hostArgs `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput $hostOutput -RedirectStandardError $hostError
  $env:NATIVEIME_TEST_HOST_PID = [string]$hostProcess.Id
  $env:NATIVEIME_TEST_ENGINE_NAME = [IO.Path]::GetFileName($engineExecutable)

  Write-Host "run-harness: waiting up to ${PipeWaitTimeoutSec}s for the pipe..."
  if (-not (Wait-ForNamedPipe -PipeFullName $pipeFullName -TimeoutSec $PipeWaitTimeoutSec)) {
    Write-Error "Timed out waiting for $pipeFullName (host pid=$($hostProcess.Id))."
    exit 1
  }

  Write-Host "run-harness: pipe up; sleeping ${ColdLoadSleepSec}s for engine cold load..."
  Start-Sleep -Seconds $ColdLoadSleepSec

  Write-Host "run-harness: launching tsf-host.exe..."
  $tsfArgs = @()
  if (-not [string]::IsNullOrEmpty($Script)) { $tsfArgs = @($Script) }

  $tsfProcess = Start-Process -FilePath $TsfHostExe -ArgumentList $tsfArgs `
    -NoNewWindow -PassThru -RedirectStandardOutput $tsfOutput -RedirectStandardError $tsfError
  try {
    Wait-Process -Id $tsfProcess.Id -Timeout $TsfHostTimeoutSec -ErrorAction Stop
    $tsfProcess.Refresh()
    $exitCode = $tsfProcess.ExitCode
  } catch {
    Write-Warning "tsf-host.exe did not exit within ${TsfHostTimeoutSec}s; killing it."
    Stop-Process -Id $tsfProcess.Id -Force -ErrorAction SilentlyContinue
    $exitCode = 124
  }
} finally {
  # The private pipe also reaches a host respawned by this test's DLL.
  Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
  if ($hostProcess -ne $null) {
    $stillRunning = $false
    try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    if ($stillRunning) {
      Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
      Start-Sleep -Milliseconds 300
      try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    }
    if ($stillRunning) {
      Write-Host "run-harness: force-killing host pid=$($hostProcess.Id)."
      Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
  }
  if (Test-Path -LiteralPath $tempJisyo) {
    Remove-Item -LiteralPath $tempJisyo -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($entry in $savedEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
  }
  if ($null -eq $savedDisableHostSpawn) {
    Remove-Item Env:NELISP_IME_DISABLE_HOST_SPAWN -ErrorAction SilentlyContinue
  } else {
    $env:NELISP_IME_DISABLE_HOST_SPAWN = $savedDisableHostSpawn
  }
}

# In particular, a host respawned by the DLL must not inherit a caller's
# captured stderr stream: a normal host diagnostic becomes NativeCommandError
# under PowerShell 5.1's ErrorActionPreference=Stop and can strand that caller.
foreach ($outputFile in @($tsfOutput, $tsfError, $hostOutput, $hostError)) {
  if ($outputFile -and (Test-Path -LiteralPath $outputFile)) {
    Get-Content -LiteralPath $outputFile -Encoding UTF8
  }
}

exit $exitCode
