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
  token grammar). SETTLE30000 waits for provider idle and 100 ms of document
  quiet, with a 30 s timeout; SETTLE30000:label preserves an AFTER label.
  WAIT remains a real-time observation window. Omit to smoke-test bring-up.

.PARAMETER TsfHostExe
  Path to tsf-host.exe. Defaults to the Release build next to this
  script's own build tree (windows/build/<Configuration>/tsf-host.exe).

.PARAMETER Configuration
  Build configuration folder name used to resolve the default
  -TsfHostExe path. Ignored if -TsfHostExe is given explicitly.

.PARAMETER ColdLoadSleepSec
  Extra sleep after the pipe appears, to clear the engine's cold load.

.PARAMETER SkipEngineWarmup
  Skip the private conversion/RESET warm-up for cold-start reproductions.

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
  [string]$CoreDllPath = "",
  [string]$CoreTestDirectory = "",
  [string]$ArtifactDirectory = "",

  # Required build-under-test paths; no installed registry defaults.
  [string]$EngineHostPath = "",
  [string]$EngineExecutablePath = "",
  [string]$RepositoryPath = "",
  [string]$RomajiProbePath = "",
  [switch]$RomajiRulesOnly,

  [string]$Configuration = "Release",
  [ValidateSet('restore','latin','hiragana','katakana')]
  [string]$OpenMode = 'restore',
  [string]$InputRulesFile = "",
  [switch]$DebugLog,
  [switch]$PublishState,
  [switch]$InlinePreedit,
  [string]$InlineDirectory = '',
  [string]$InlinePidFile = '',
  [string]$CaretMapName = '',
  [ValidateSet("", "selection", "left-key")][string]$AutoPairCaret = "",
  [ValidateRange(0,1)][int]$LocalConversion = 0,
  [ValidateRange(-1,1)][int]$ApplicationLocalConversion = -1,
  [ValidateSet('none','missing','corrupt')][string]$LocalIndexFailure = 'none',
  [switch]$StopEngineAfterWarmup,

  # Engine cold load has been measured anywhere from 3.4s (quiet machine)
  # to ~12s (loaded machine); a 6s default let the first scripted keys race
  # the load and get swallowed, which read as false engine regressions.
  [int]$ColdLoadSleepSec = 12,
  [switch]$SkipEngineWarmup,

  [int]$PipeWaitTimeoutSec = 30,

  [int]$TsfHostTimeoutSec = 60
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# Record only children of the host we started, so a forced host shutdown
# cannot strand its runtime or accidentally kill another worker's process.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class NativeImeHarnessChildren {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Entry {
    public uint size, usage, pid; public UIntPtr heap;
    public uint module, threads, parent; public int priority; public uint flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string name;
  }
  [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32FirstW(IntPtr h, ref Entry e);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool Process32NextW(IntPtr h, ref Entry e);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool WaitNamedPipeW(string name, uint timeout);
  public static int[] Find(int parent, string name) {
    var found = new List<int>(); var h = CreateToolhelp32Snapshot(2, 0);
    if (h == new IntPtr(-1)) return found.ToArray();
    var e = new Entry(); e.size = (uint)Marshal.SizeOf(e);
    if (Process32FirstW(h, ref e)) do {
      if (e.parent == parent && String.Equals(e.name, name, StringComparison.OrdinalIgnoreCase)) found.Add((int)e.pid);
    } while (Process32NextW(h, ref e));
    CloseHandle(h); return found.ToArray();
  }
}
'@

function Wait-ForNamedPipe {
  param(
    [Parameter(Mandatory)] [string]$PipeFullName,
    [Parameter(Mandatory)] [int]$TimeoutSec
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    # A filesystem probe opens/closes a pipe and can race ConnectNamedPipe
    # into ERROR_NO_DATA. WaitNamedPipe observes readiness without a client.
    if ([NativeImeHarnessChildren]::WaitNamedPipeW($PipeFullName, 100)) { return $true }
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
    'LOCALAPPDATA','APPDATA','NELISP_IME_INLINE_DIR','NATIVEIME_TEST_CARET_MAP','NELISP_IME_ENGINE','NATIVEIME_TEST_HOST_PID','NATIVEIME_TEST_ENGINE_NAME','DDSKK_HARNESS_DLL_PATH','NATIVEIME_TEST_CORE_DIRECTORY','NATIVEIME_TEST_CORE_ACTION_SCRIPT','NATIVEIME_HARNESS_TSF_OUTPUT')) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$hostProcess = $null
$startedChildren = @()
$exitCode = 1
$savedDisableHostSpawn = $env:NELISP_IME_DISABLE_HOST_SPAWN
try {
$env:NATIVEIME_TEST_CORE_ACTION_SCRIPT = Join-Path $PSScriptRoot 'core-test-action.ps1'
$env:DDSKK_HARNESS_DLL_PATH = $DllPath
if ($CoreTestDirectory) { $env:NATIVEIME_TEST_CORE_DIRECTORY = [IO.Path]::GetFullPath($CoreTestDirectory) }
$env:DDSKK_PIPE_NAME = $pipeFullName
$env:DDSKK_USER_JISYO = $tempJisyo
$env:NATIVEIME_REGISTRY_KEY = $registryKey
$env:NATIVEIME_TEST_CARET_MAP = if ($CaretMapName) { $CaretMapName } else { "Local\ddskk-test-caret-$runId" }
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
if ($CoreDllPath) {
  New-ItemProperty -Path $regPath -Name CoreDll -Value ([IO.Path]::GetFullPath($CoreDllPath)) -PropertyType String -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name SkkServEnable -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $regPath -Name InitialKanaMode -Value 1 -PropertyType DWord -Force | Out-Null
if ($env:DDSKK_HARNESS_LOCAL_CONVERSION -eq '1') { $LocalConversion = 1 }
New-ItemProperty -Path $regPath -Name LocalConversion -Value $LocalConversion -PropertyType DWord -Force | Out-Null
if ($DebugLog) { New-ItemProperty -Path $regPath -Name DebugLog -Value 1 -PropertyType DWord -Force | Out-Null }
if ($AutoPairCaret) {
  $appPath = Join-Path $regPath ('Apps\' + [IO.Path]::GetFileName($TsfHostExe).ToLowerInvariant())
  New-Item -Path $appPath -Force | Out-Null
  New-ItemProperty -Path $appPath -Name AutoPairCaret -Value $AutoPairCaret -PropertyType String -Force | Out-Null
}
if ($ApplicationLocalConversion -ge 0) {
  $appPath = Join-Path $regPath ('Apps\' + [IO.Path]::GetFileName($TsfHostExe).ToLowerInvariant())
  New-Item -Path $appPath -Force | Out-Null
  New-ItemProperty -Path $appPath -Name LocalConversion -Value $ApplicationLocalConversion -PropertyType DWord -Force | Out-Null
}
if ($InlineDirectory) { $env:NELISP_IME_INLINE_DIR = [IO.Path]::GetFullPath($InlineDirectory) }
if ($PublishState -or $InlinePreedit -or $OpenMode -ne 'restore') {
  $appPath = Join-Path $regPath ('Apps\' + [IO.Path]::GetFileName($TsfHostExe).ToLowerInvariant())
  New-Item -Path $appPath -Force | Out-Null
  New-ItemProperty -Path $appPath -Name OpenMode -Value $OpenMode -PropertyType String -Force | Out-Null
  New-ItemProperty -Path $appPath -Name PublishState -Value ([int][bool]$PublishState) -PropertyType DWord -Force | Out-Null
  New-ItemProperty -Path $appPath -Name InlinePreedit -Value ([int][bool]$InlinePreedit) -PropertyType DWord -Force | Out-Null
}
# Logs and user data must also stay out of the installed IME's directory.
if (-not $ArtifactDirectory) { $ArtifactDirectory = $env:NATIVEIME_HARNESS_ARTIFACT_DIRECTORY }
$artifactRoot = if ($ArtifactDirectory) { [IO.Path]::GetFullPath($ArtifactDirectory) } else { [IO.Path]::GetDirectoryName($TsfHostExe) }
$env:LOCALAPPDATA = Join-Path $artifactRoot "harness-$runId"
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
$env:APPDATA = Join-Path $env:LOCALAPPDATA 'appdata'
New-Item -ItemType Directory -Path (Join-Path $env:APPDATA 'NativeIME') -Force | Out-Null
if ($InputRulesFile) {
  Copy-Item -LiteralPath $InputRulesFile -Destination (Join-Path $env:APPDATA 'NativeIME/input-rules.conf')
}
$hostOutput = Join-Path $env:LOCALAPPDATA 'host.stdout.log'
$hostError = Join-Path $env:LOCALAPPDATA 'host.stderr.log'
$tsfOutput = Join-Path $env:LOCALAPPDATA 'tsf.stdout.log'
$tsfError = Join-Path $env:LOCALAPPDATA 'tsf.stderr.log'
# SETTLE reads only this run's redirected diagnostics, never a live IME.
$env:NATIVEIME_HARNESS_TSF_OUTPUT = $tsfOutput
# The registry is authoritative for live-switch tests, so do not pin the DLL.
Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue
Remove-Item Env:NELISP_IME_DISABLE_HOST_SPAWN -ErrorAction SilentlyContinue

Write-Host "run-harness: pipe=$pipeFullName jisyo=$tempJisyo"
Write-Host "run-harness: starting engine host: [$engineHost] [$engineExecutable] [$repository]"

$hostArgs = @("`"$engineExecutable`"")
if (-not [string]::IsNullOrWhiteSpace($repository)) { $hostArgs += "`"$repository`"" }

  $hostProcess = Start-Process -FilePath $engineHost -ArgumentList $hostArgs `
    -WindowStyle Hidden -PassThru -RedirectStandardOutput $hostOutput -RedirectStandardError $hostError
  Write-Host "HARNESS_HOST pid=$($hostProcess.Id)"
  $env:NATIVEIME_TEST_HOST_PID = [string]$hostProcess.Id
  $env:NATIVEIME_TEST_ENGINE_NAME = [IO.Path]::GetFileName($engineExecutable)

  Write-Host "run-harness: waiting up to ${PipeWaitTimeoutSec}s for the pipe..."
  if (-not (Wait-ForNamedPipe -PipeFullName $pipeFullName -TimeoutSec $PipeWaitTimeoutSec)) {
    Write-Error "Timed out waiting for $pipeFullName (host pid=$($hostProcess.Id))."
    exit 1
  }

  Write-Host "run-harness: pipe up; sleeping ${ColdLoadSleepSec}s for engine cold load..."
  Start-Sleep -Seconds $ColdLoadSleepSec
  if (-not $SkipEngineWarmup) {
    # Prime the private engine before measuring keys. Lowercase ai + Space
    # is direct input in DDSKK and cannot warm its dictionary conversion.
    foreach ($request in @('CONTROL CONVERT-KEYS 75,97', 'RESET')) {
      $warmPipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeShortName,
        [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
      try {
        $warmPipe.Connect(30000)
        $bytes = [Text.Encoding]::ASCII.GetBytes($request + "`n")
        $warmPipe.Write($bytes, 0, $bytes.Length)
        $buffer = New-Object byte[] 65536
        $reply = $warmPipe.ReadAsync($buffer, 0, $buffer.Length)
        if (-not $reply.Wait(30000)) { throw 'Private engine warm-up timed out' }
        $response = [Text.Encoding]::UTF8.GetString($buffer, 0, $reply.Result).Trim()
        if ($response -notlike 'STATE *') { throw "Engine warm-up failed: $response" }
        Write-Host "ENGINE_WARMUP request=$request reply=$response"
      } finally { $warmPipe.Dispose() }
    }
  }
  $startedChildren = @([NativeImeHarnessChildren]::Find($hostProcess.Id, [IO.Path]::GetFileName($engineExecutable)) |
    ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  foreach ($child in $startedChildren) { Write-Host "HARNESS_CHILD pid=$($child.Id) parent=$($hostProcess.Id)" }
  if ($LocalConversion -eq 1 -or $ApplicationLocalConversion -eq 1) {
    $deadline = (Get-Date).AddSeconds(30)
    do {
      $manifests = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Filter current -Recurse -File)
      if ($manifests.Count) { break }
      Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    if (-not $manifests.Count) { throw 'Local index publication timeout' }
    if ($LocalIndexFailure -ne 'none') {
      foreach ($manifest in $manifests) {
        $generation = Join-Path $manifest.DirectoryName ([IO.File]::ReadAllText($manifest.FullName))
        if ($LocalIndexFailure -eq 'missing') { Remove-Item -LiteralPath $generation -Force }
        else {
          $bytes = [IO.File]::ReadAllBytes($generation)
          $bytes[$bytes.Length-1] = $bytes[$bytes.Length-1] -bxor 1
          [IO.File]::WriteAllBytes($generation, $bytes)
        }
      }
    }
  }
  if ($StopEngineAfterWarmup) {
    Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
    if (-not $hostProcess.WaitForExit(10000)) { throw 'Owned offline-test host did not stop' }
    Write-Host 'HARNESS_ENGINE_OFFLINE'
  }

  if ($RomajiProbePath) {
    $probePipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeShortName,
        [IO.Pipes.PipeDirection]::InOut)
    try {
      $probePipe.Connect(5000)
      $probePipe.ReadMode = [IO.Pipes.PipeTransmissionMode]::Message
      function Invoke-RomajiProbe([string]$request) {
        $bytes = [Text.Encoding]::ASCII.GetBytes($request + "`n")
        $probePipe.Write($bytes, 0, $bytes.Length)
        $buffer = New-Object byte[] 65536
        $count = $probePipe.Read($buffer, 0, $buffer.Length)
        return [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
      }
      $rules = Invoke-RomajiProbe 'ROMAJI RULES 1'
      if (-not $rules.StartsWith('RULES 1 ')) { throw "Rule export failed: $rules" }
      $probeLines = [Collections.Generic.List[string]]::new()
      $probeLines.Add($rules)
      foreach ($record in $rules.Substring(8).Split(' ')) {
        if ($RomajiRulesOnly) { break }
        $fields = $record.Split(':')
        if ($fields[4] -ne '-') { continue } # Commands use TSF routing tests.
        $keys = for ($i = 0; $i -lt $fields[0].Length; $i += 6) {
          [Convert]::ToInt32($fields[0].Substring($i, 6), 16)
        }
        foreach ($katakana in @($false, $true)) {
          $probeKeys = if ($katakana) { @(113) + @($keys) } else { @($keys) }
          $reply = Invoke-RomajiProbe ('SESSION romaji-oracle CONTROL SYNC-KEYS ' + ($probeKeys -join ','))
          $probeLines.Add($(if ($katakana) { '000071' } else { '' }) + $fields[0] + ' ' + $reply)
        }
      }
      foreach ($sample in @('tya', 'tyu', 'tyo', 'tta', 'nn', "n'", 'nka', 'z.', 'z/')) {
        if ($RomajiRulesOnly) { break }
        $keys = @($sample.ToCharArray() | ForEach-Object { [int]$_ })
        $reply = Invoke-RomajiProbe ('SESSION romaji-oracle CONTROL SYNC-KEYS ' + ($keys -join ','))
        $hexKey = ($keys | ForEach-Object { $_.ToString('x6') }) -join ''
        $probeLines.Add($hexKey + ' ' + $reply)
      }
      [IO.File]::WriteAllLines([IO.Path]::GetFullPath($RomajiProbePath), $probeLines, $utf8)
      Write-Host "ROMAJI probes=$($probeLines.Count - 1) file=$RomajiProbePath"
    } finally { $probePipe.Dispose() }
  }

  Write-Host "run-harness: launching tsf-host.exe..."
  $tsfArgs = @()
  if (-not [string]::IsNullOrEmpty($Script)) { $tsfArgs = @($Script) }

  $tsfProcess = Start-Process -FilePath $TsfHostExe -ArgumentList $tsfArgs `
    -NoNewWindow -PassThru -RedirectStandardOutput $tsfOutput -RedirectStandardError $tsfError
  # Cache the handle before exit. Windows PowerShell's Wait-Process can
  # otherwise leave Start-Process's ExitCode null, silently skipping checks.
  Write-Host "HARNESS_TSF pid=$($tsfProcess.Id)"
  if ($InlinePidFile) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($InlinePidFile), [string]$tsfProcess.Id) }
  $tsfHandle = $tsfProcess.Handle
  try {
    if (-not $tsfProcess.WaitForExit($TsfHostTimeoutSec * 1000)) { throw 'TSF host timeout' }
    $exitCode = $tsfProcess.ExitCode
    if ($null -eq $exitCode) { throw 'TSF host exit code unavailable' }
  } catch {
    Write-Warning "tsf-host.exe did not exit within ${TsfHostTimeoutSec}s; killing it."
    Stop-Process -Id $tsfProcess.Id -Force -ErrorAction SilentlyContinue
    $exitCode = 124
  }
    if ($PublishState -and $exitCode -eq 0) {
      $clientPath = Join-Path $regPath "Clients\$($tsfProcess.Id)"
      # Normal deactivation removes it immediately; a forcibly terminated
      # process relies on the host's dead-PID sweep.
      $deadline = (Get-Date).AddSeconds(3)
      while ((Test-Path -LiteralPath $clientPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
      }
      if (Test-Path -LiteralPath $clientPath) { throw 'Client entry survived tsf-host exit' }
      Write-Host 'CLIENT_EXIT_REMOVED=1'
    }
} finally {
  # The private pipe also reaches a host respawned by this test's DLL.
  Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
  if ($hostProcess -ne $null) {
    $stillRunning = $false
    try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    if ($stillRunning) {
      Send-ShutdownRequest -PipeShortName $pipeShortName | Out-Null
      $hostProcess.WaitForExit(6000) | Out-Null
      try { $stillRunning = -not $hostProcess.HasExited } catch { $stillRunning = $false }
    }
    if ($stillRunning) {
      Write-Host "run-harness: force-killing host pid=$($hostProcess.Id)."
      Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
    }
    [void]$hostProcess.WaitForExit(5000)
    Write-Host "HARNESS_HOST_EXITED pid=$($hostProcess.Id) exited=$($hostProcess.HasExited)"
  }
  foreach ($child in $startedChildren) {
    try {
      $child.Refresh()
      if (-not $child.HasExited) {
        Stop-Process -Id $child.Id -Force -ErrorAction Stop
        $child.WaitForExit(5000) | Out-Null
      }
      Write-Host "HARNESS_CHILD_EXITED pid=$($child.Id) exited=$($child.HasExited)"
    } catch { Write-Warning "Could not verify owned runtime pid=$($child.Id): $_" }
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
  # Preserve child diagnostics even if preflight/probing throws before TSF
  # starts. The cleanup above must always precede surfacing those logs.
  foreach ($outputFile in @($tsfOutput, $tsfError, $hostOutput, $hostError)) {
    if ($outputFile -and (Test-Path -LiteralPath $outputFile)) {
      Get-Content -LiteralPath $outputFile -Encoding UTF8
    }
  }
}

# In particular, a host respawned by the DLL must not inherit a caller's
# captured stderr stream: a normal host diagnostic becomes NativeCommandError
# under PowerShell 5.1's ErrorActionPreference=Stop and can strand that caller.

exit $exitCode
