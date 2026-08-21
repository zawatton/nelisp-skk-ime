<#
.SYNOPSIS
  Deploy the rebuilt DLL, host exe, and/or a refreshed engine snapshot to
  the live DDSKK IME installation.

.DESCRIPTION
  Consolidates four ad-hoc, session-only scratchpad scripts into one
  maintained, parameterized tool. See README.md in this directory for the
  full deployment model (timestamped immutable directories, live snapshot
  freeze, prewarm rationale). In short:

    -Dll        Copy windows/build/Release/ddskk-ime.dll into a new
                timestamped %LOCALAPPDATA%\DDSKK directory and repoint
                ONLY the CLSID InprocServer32 default value at it.
                DllRegisterServer is NEVER invoked (its Repository
                derivation corrupted the registry once). Any application
                that already loaded the DLL must be restarted by the user
                to pick up the change -- this script cannot do that for
                them, and says so in its output.

    -HostExe    Copy windows/build/Release/ddskk-engine-host.exe into a
                new timestamped directory. Combined with the shared
                restart step below, this updates
                HKCU\Software\NativeIME\EngineHost, restarts the live
                host (only ddskk-engine-host.exe processes are ever
                stopped), and warms it.
                (Named -HostExe, not -Host: PowerShell's automatic $Host
                variable is read-only/constant, so a script parameter
                literally cannot be named -Host -- confirmed the hard way
                during -DryRun validation of this script.)

    -Engine     Refresh the frozen live engine snapshot: robocopy this
                repository (minus build output and VCS metadata) plus its
                ..\nelisp\src\nelisp-buffer.el sibling dependency into a
                new timestamped "live-<stamp>" directory, PRE-WARM that
                fresh snapshot on a private pipe with a private user
                dictionary before switching anything live to it, then
                (via the shared steps below) update
                HKCU\Software\NativeIME\Repository and restart the live
                host onto the new snapshot.

    -Indicator  Copy the rebuilt sumi-skk-ui.exe into the timestamped
                runtime directory, update SettingsExe, and restart the
                resident Sumi process on the default pipe.

  All four switches are independently combinable. -HostExe and -Engine share
  a single restart-and-verify step at the end, so passing both together
  restarts the live host exactly once, already pointed at both the new
  exe and the new snapshot. Running with none of the four switches prints
  usage and does nothing.

  -DryRun prints every action this script would take -- file copies,
  registry reads/writes, process stop/start, and live-pipe round trips --
  and performs NONE of them. It never touches the registry, never
  enumerates or stops processes, and never opens a named pipe, so it has
  no dependency on the target machine actually having DDSKK installed.
  This is what makes it safe to run anywhere and is this script's own
  test vehicle; see README.md.

  Immediately before changing registry pointers, a rollback.json manifest
  records all previous paths. Pass it to rollback-live.ps1 to restore the
  older runtime without copying over either version.

.PARAMETER Dll
  Deploy the rebuilt ddskk-ime.dll and repoint the CLSID InprocServer32
  default value at it.

.PARAMETER HostExe
  Deploy the rebuilt ddskk-engine-host.exe (registry update and restart
  happen in the shared step below, alongside -Engine if also given).

.PARAMETER Engine
  Refresh the live engine snapshot, prewarmed on a private pipe before
  anything live is switched to it (registry update and restart happen in
  the shared step below, alongside -HostExe if also given).

.PARAMETER Indicator
  Deploy and restart the Sumi indicator/candidate/registration UI.

.PARAMETER DryRun
  Print every action without performing it. Required test vehicle for
  this script; see README.md. No live-system dependency in this mode.

.PARAMETER RepoRoot
  Path to the nelisp-skk-ime repository. Defaults to the repository this
  script lives in (two levels above windows/scripts).

.PARAMETER NelispBufferElSource
  Path to the nelisp-buffer.el sibling dependency copied alongside the
  engine snapshot. Defaults to ..\nelisp\src\nelisp-buffer.el next to
  RepoRoot, matching the normal sibling-repository layout under dev\.

.PARAMETER WarmTimeoutSeconds
  How long to wait for the restarted live host to answer on its pipe.

.PARAMETER PrewarmTimeoutMinutes
  How long to wait for a freshly copied engine snapshot's first boot to
  answer STATUS on its private prewarm pipe. Generous by default because
  a cold antivirus scan of a freshly copied tree has been observed to
  take on the order of tens of minutes under concurrent build load; see
  README.md.

.EXAMPLE
  pwsh -File windows\scripts\deploy-live.ps1 -Dll -DryRun

.EXAMPLE
  pwsh -File windows\scripts\deploy-live.ps1 -Dll -HostExe -Engine -Indicator
#>
param(
  [switch]$Dll,
  [switch]$HostExe,
  [switch]$Engine,
  [switch]$Indicator,
  [switch]$DryRun,
  [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  [string]$NelispBufferElSource,
  [int]$WarmTimeoutSeconds = 60,
  [int]$PrewarmTimeoutMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $NelispBufferElSource) {
  $NelispBufferElSource = Join-Path (Split-Path -Parent $RepoRoot) 'nelisp\src\nelisp-buffer.el'
}

# ---------------------------------------------------------------------------
# Deployment-model constants. See README.md for the reasoning behind each
# of these; the values themselves are the same ones the four scratchpad
# scripts this replaces (deploy-dll.ps1, deploy-host.ps1,
# deploy-jisyo-pipeline.ps1, refresh-live-snapshot.ps1) used.
# ---------------------------------------------------------------------------
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LiveRoot = Join-Path $env:LOCALAPPDATA 'DDSKK'
# ddskk-ime.dll and ddskk-engine-host.exe share one timestamped bin dir per
# invocation when both are deployed together; the engine snapshot gets its
# own "live-<stamp>" dir, matching the original scripts' naming.
$BinDir = Join-Path $LiveRoot $Stamp
$SnapshotRoot = Join-Path $LiveRoot "live-$Stamp"
$NativeImeKey = 'HKCU:\Software\NativeIME'
$UserRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$SumiRunValue = 'NeLisp IME Sumi'
$ClsidKey = 'HKCU:\Software\Classes\CLSID\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\InprocServer32'
$DllSrc = Join-Path $RepoRoot 'windows\build\Release\ddskk-ime.dll'
$HostSrc = Join-Path $RepoRoot 'windows\build\Release\ddskk-engine-host.exe'
$IndicatorExe = Join-Path $RepoRoot 'sumi-ui\target\sumi-skk-ui.exe'
$LivePipeName = 'ddskk-ime-v1'

# Only ddskk-engine-host.exe processes are ever stopped by this script --
# never any other NeLisp process, and never an application that merely has
# the DLL loaded (that case is handled by the -Dll restart-reminder above,
# not by stopping anything).
$HostProcessName = 'ddskk-engine-host.exe'
$IndicatorProcessName = 'sumi-skk-ui'

# Explicitly cleared before starting the live host so it serves the
# DEFAULT pipe, default user dictionary, default save-batch size, and
# default idle-GC interval, instead of silently inheriting a leftover
# probe/test override from this or a parent shell.
$EnvVarsToClear = @(
  'DDSKK_PIPE_NAME',
  'DDSKK_USER_JISYO',
  'DDSKK_USER_JISYO_SAVE_BATCH_SIZE',
  'DDSKK_ENGINE_IDLE_GC_MS'
)

# ---------------------------------------------------------------------------
# Shared helpers. Every one of them honors $DryRun by printing what it
# would do and returning without touching the filesystem, the registry, a
# process, or a pipe -- this is the single choke point that makes -DryRun
# a complete, live-system-independent preview instead of a partial one.
# ---------------------------------------------------------------------------
function Write-Step {
  param([Parameter(Mandatory = $true)][string]$Message)
  if ($DryRun) { Write-Host "[DRYRUN] $Message" }
  else { Write-Host $Message }
}

function Copy-Deployed {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Destination
  )
  if ($DryRun) {
    Write-Step "would create directory $(Split-Path -Parent $Destination)"
    Write-Step "would copy $Source -> $Destination"
    return
  }
  if (-not (Test-Path -LiteralPath $Source)) { throw "source file not found: $Source" }
  New-Item -ItemType Directory -Force (Split-Path -Parent $Destination) | Out-Null
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  Write-Host "COPY  : $Source -> $Destination ($((Get-Item -LiteralPath $Destination).LastWriteTime))"
}

# Read-only registry lookup used for narration and for filling in values
# this script did not itself just deploy (e.g. EngineExecutable, which is
# never written by this script). Under -DryRun this never touches the
# registry -- it returns a placeholder string so every downstream action
# can still be narrated without any live-system dependency.
function Get-NativeImeValue {
  param([Parameter(Mandatory = $true)][string]$Name)
  if ($DryRun) { return "<$Name from $NativeImeKey>" }
  $value = (Get-ItemProperty -Path $NativeImeKey -ErrorAction SilentlyContinue).$Name
  if (-not $value) {
    throw "$NativeImeKey\$Name is not set; configure it (e.g. via the settings UI) before deploying."
  }
  return $value
}

function Set-NativeImeValue {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )
  if ($DryRun) { Write-Step "would set $NativeImeKey\$Name = $Value"; return }
  Set-ItemProperty -Path $NativeImeKey -Name $Name -Value $Value
  Write-Host "REG   : $NativeImeKey\$Name = $Value"
}

function Set-ClsidDefault {
  param([Parameter(Mandatory = $true)][string]$Value)
  if ($DryRun) { Write-Step "would set $ClsidKey (default) = $Value"; return }
  $old = (Get-ItemProperty -Path $ClsidKey -ErrorAction SilentlyContinue).'(default)'
  Set-ItemProperty -Path $ClsidKey -Name '(default)' -Value $Value
  Write-Host "REG   : $ClsidKey (default): $old -> $Value"
}

function Get-RegistryValueOrNull {
  param([string]$Path, [string]$Name)
  $item = Get-ItemProperty -Path $Path -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $null }
  $property = $item.PSObject.Properties[$Name]
  if ($null -eq $property) { return $null }
  return $property.Value
}

function Stop-LiveHost {
  if ($DryRun) { Write-Step "would stop all running $HostProcessName processes"; return }
  Get-CimInstance Win32_Process -Filter "Name='$HostProcessName'" | ForEach-Object {
    Write-Host "STOP  : pid=$($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 400
}

function Clear-DdskkEnv {
  foreach ($name in $EnvVarsToClear) {
    if ($DryRun) { Write-Step "would clear env:$name"; continue }
    Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
  }
}

function Start-EngineHost {
  param(
    [Parameter(Mandatory = $true)][string]$HostExe,
    [Parameter(Mandatory = $true)][string]$NelispExe,
    [Parameter(Mandatory = $true)][string]$RepositoryDir
  )
  if ($DryRun) {
    Write-Step "would start `"$HostExe`" `"$NelispExe`" `"$RepositoryDir`" (cwd=$RepositoryDir)"
    return $null
  }
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $HostExe
  # ProcessStartInfo.ArgumentList is unavailable in the Windows PowerShell
  # 5.1 used by this machine.  These are both paths, so quote each argument
  # explicitly for the compatible Arguments property instead.
  $psi.Arguments = '"{0}" "{1}"' -f $NelispExe, $RepositoryDir
  $psi.WorkingDirectory = $RepositoryDir
  $psi.UseShellExecute = $false
  $proc = [Diagnostics.Process]::Start($psi)
  Write-Host "START : pid=$($proc.Id) $HostExe"
  return $proc
}

function Connect-LivePipe {
  param(
    [Parameter(Mandatory = $true)][string]$PipeName,
    [int]$TimeoutSeconds = 60
  )
  if ($DryRun) {
    Write-Step "would connect to \\.\pipe\$PipeName (retrying for up to ${TimeoutSeconds}s)"
    return $null
  }
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $p = [IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [IO.Pipes.PipeDirection]::InOut)
      $p.Connect(500)
      $p.ReadMode = [IO.Pipes.PipeTransmissionMode]::Message
      return $p
    } catch { Start-Sleep -Milliseconds 250 }
  }
  throw "pipe \\.\pipe\$PipeName did not come up within $TimeoutSeconds s"
}

function Send-PipeCommand {
  param(
    # Not [Parameter(Mandatory)]: under -DryRun, Connect-LivePipe legitimately
    # returns $null (see its own -DryRun branch), and PowerShell rejects an
    # explicit $null argument for a Mandatory parameter even when the callee
    # would otherwise happily no-op on it -- caught by this script's own
    # -DryRun validation run.
    $Pipe,
    [Parameter(Mandatory = $true)][string]$Command
  )
  if ($DryRun) {
    Write-Step "would send `"$Command`" on the connected pipe"
    return $null
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes("$Command`n")
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $Pipe.Write($bytes, 0, $bytes.Length)
  $Pipe.Flush()
  $buf = [byte[]]::new(4096)
  $n = $Pipe.Read($buf, 0, $buf.Length)
  $reply = [Text.Encoding]::UTF8.GetString($buf, 0, $n).Trim()
  Write-Host ("{0,-8}: {1} ms [{2}]" -f $Command, $sw.ElapsedMilliseconds, $reply)
  return $reply
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
if (-not ($Dll -or $HostExe -or $Engine -or $Indicator)) {
  Write-Host 'Nothing to do: pass at least one of -Dll -HostExe -Engine -Indicator (add -DryRun to preview).'
  return
}

Write-Host "=== deploy-live.ps1 $(if ($DryRun) { '(DRY RUN -- nothing will be changed)' }) stamp=$Stamp ==="

# 1. DLL: independent of everything else below; never touches the running
#    host process. The registry switch is deferred until after rollback.json
#    has captured the old pointer in step 5.
$dllDest = $null
if ($Dll) {
  Write-Host '--- DLL ---'
  $dllDest = Join-Path $BinDir 'ddskk-ime.dll'
  Copy-Deployed -Source $DllSrc -Destination $dllDest
  Write-Host 'NOTE  : ddskk-ime.dll is an in-process COM server; any application that'
  Write-Host '        already loaded the old copy must be RESTARTED by the user to pick'
  Write-Host '        up this change. DllRegisterServer is never invoked (see README.md).'
}

# 2. Host exe copy only. The registry write and the restart are deferred to
#    step 4/5 below so a combined -HostExe -Engine run restarts the live
#    host exactly once, already pointed at both the new exe and new
#    snapshot.
$hostDest = $null
if ($HostExe) {
  Write-Host '--- HOST EXE ---'
  $hostDest = Join-Path $BinDir 'ddskk-engine-host.exe'
  Copy-Deployed -Source $HostSrc -Destination $hostDest
}

# 2b. Sumi UI copy. Registry update and restart happen below, after the
# immutable destination exists. Candidate and dictionary-registration UI
# live in this process, not in the TSF DLL.
$indicatorDest = $null
if ($Indicator) {
  Write-Host '--- SUMI UI ---'
  $indicatorDest = Join-Path $BinDir 'sumi-skk-ui.exe'
  Copy-Deployed -Source $IndicatorExe -Destination $indicatorDest
}

# 3. Engine snapshot: robocopy + sibling file + PREWARM, all before
#    anything live is touched. See README.md for why the prewarm step
#    exists.
$snapshotDir = $null
if ($Engine) {
  Write-Host '--- ENGINE SNAPSHOT ---'
  $snapshotDir = Join-Path $SnapshotRoot 'nelisp-skk-ime'
  if ($DryRun) {
    Write-Step "would robocopy $RepoRoot -> $snapshotDir (/E /XD .git build target node_modules .tmp-home /XF *.o *.obj *.exe *.dll)"
    Write-Step "would copy $NelispBufferElSource -> $SnapshotRoot\nelisp\src\nelisp-buffer.el"
  } else {
    robocopy $RepoRoot $snapshotDir /E /XD .git build target node_modules .tmp-home /XF *.o *.obj *.exe *.dll /NFL /NDL /NJH /NJS | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    $bufferDestDir = Join-Path $SnapshotRoot 'nelisp\src'
    New-Item -ItemType Directory -Force $bufferDestDir | Out-Null
    Copy-Item -LiteralPath $NelispBufferElSource -Destination (Join-Path $bufferDestDir 'nelisp-buffer.el')
    Write-Host "SNAP  : $snapshotDir"
  }

  Write-Host '--- ENGINE PREWARM ---'
  # Pre-warm the fresh snapshot on a PRIVATE pipe, with a private/temp user
  # dictionary, before switching the live IME to it: the first boot of a
  # freshly copied tree pays antivirus real-time scanning of every file it
  # touches (observed once at roughly 38 minutes under concurrent build
  # load); a second boot of the same already-scanned tree is seconds. This
  # step pays that cost off to the side so the live restart in step 5
  # below never exposes the user to it.
  $prewarmHostExe = if ($hostDest) { $hostDest } else { Get-NativeImeValue 'EngineHost' }
  $nelispExe = Get-NativeImeValue 'EngineExecutable'
  $prewarmPipeName = "ddskk-prewarm-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
  if ($DryRun) {
    Write-Step "would set env DDSKK_PIPE_NAME=\\.\pipe\$prewarmPipeName and DDSKK_USER_JISYO=<temp jisyo> for the prewarm child only"
    Write-Step "would start `"$prewarmHostExe`" `"$nelispExe`" `"$snapshotDir`" and wait up to $PrewarmTimeoutMinutes min for it to answer STATUS"
    Write-Step 'would send SHUTDOWN to the prewarm child, then clear the prewarm-only env vars'
  } else {
    $prewarmJisyo = Join-Path $env:TEMP 'deploy-live-prewarm-jisyo.utf8'
    $env:DDSKK_PIPE_NAME = "\\.\pipe\$prewarmPipeName"
    $env:DDSKK_USER_JISYO = $prewarmJisyo
    $prewarmProc = $null
    $prewarmPipe = $null
    try {
      $prewarmProc = Start-EngineHost -HostExe $prewarmHostExe -NelispExe $nelispExe -RepositoryDir $snapshotDir
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $prewarmPipe = Connect-LivePipe -PipeName $prewarmPipeName -TimeoutSeconds ($PrewarmTimeoutMinutes * 60)
      Send-PipeCommand -Pipe $prewarmPipe -Command 'STATUS' | Out-Null
      Write-Host ("PREWARM: first boot {0:n0} ms" -f $sw.ElapsedMilliseconds)
      try { Send-PipeCommand -Pipe $prewarmPipe -Command 'SHUTDOWN' | Out-Null } catch {}
    } finally {
      if ($prewarmPipe) { $prewarmPipe.Dispose() }
      if ($prewarmProc -and -not $prewarmProc.WaitForExit(5000)) { $prewarmProc.Kill() }
      Remove-Item -Force -ErrorAction SilentlyContinue $prewarmJisyo
      Remove-Item Env:\DDSKK_PIPE_NAME -ErrorAction SilentlyContinue
      Remove-Item Env:\DDSKK_USER_JISYO -ErrorAction SilentlyContinue
    }
  }
}

# 4. Save exact old pointers before any registry write. The manifest lives
#    inside this deployment's immutable directory.
$manifestDir = if ($Dll -or $HostExe -or $Indicator) { $BinDir } else { $SnapshotRoot }
$manifestPath = Join-Path $manifestDir 'rollback.json'
if ($DryRun) {
  Write-Step "would save previous DLL/host/repository/Sumi registry pointers to $manifestPath"
} else {
  New-Item -ItemType Directory -Force $manifestDir | Out-Null
  $manifest = [ordered]@{
    schema = 1
    created_at = (Get-Date).ToString('o')
    deployed_bin = if ($Dll -or $HostExe -or $Indicator) { $BinDir } else { $null }
    deployed_snapshot = if ($Engine) { $SnapshotRoot } else { $null }
    previous = [ordered]@{
      dll = Get-RegistryValueOrNull -Path $ClsidKey -Name '(default)'
      engine_host = Get-RegistryValueOrNull -Path $NativeImeKey -Name 'EngineHost'
      repository = Get-RegistryValueOrNull -Path $NativeImeKey -Name 'Repository'
      settings_exe = Get-RegistryValueOrNull -Path $NativeImeKey -Name 'SettingsExe'
      sumi_run = Get-RegistryValueOrNull -Path $UserRunKey -Name $SumiRunValue
    }
  }
  $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  Write-Host "ROLLBK: $manifestPath"
}

# 5. Registry writes. SettingsExe is updated only with -Indicator; the
#    engine and DLL switches retain their previous narrow write sets.
if ($dllDest) { Set-ClsidDefault -Value $dllDest }
if ($hostDest) { Set-NativeImeValue -Name 'EngineHost' -Value $hostDest }
if ($snapshotDir) { Set-NativeImeValue -Name 'Repository' -Value $snapshotDir }
if ($indicatorDest) {
  Set-NativeImeValue -Name 'SettingsExe' -Value $indicatorDest
  $runCommand = '"' + $indicatorDest + '"'
  if ($DryRun) {
    Write-Step "would set $UserRunKey\$SumiRunValue = $runCommand"
  } else {
    Set-ItemProperty -Path $UserRunKey -Name $SumiRunValue -Value $runCommand
    Write-Host "REG   : $UserRunKey\$SumiRunValue = $runCommand"
  }
}

# 6. Restart the live host if its exe or its snapshot changed, then verify
#    it over the live pipe.
if ($HostExe -or $Engine) {
  Write-Host '--- RESTART LIVE HOST ---'
  Stop-LiveHost
  Clear-DdskkEnv
  $liveHostExe = if ($hostDest) { $hostDest } else { Get-NativeImeValue 'EngineHost' }
  $liveNelispExe = Get-NativeImeValue 'EngineExecutable'
  $liveRepo = if ($snapshotDir) { $snapshotDir } else { Get-NativeImeValue 'Repository' }
  Start-EngineHost -HostExe $liveHostExe -NelispExe $liveNelispExe -RepositoryDir $liveRepo | Out-Null

  Write-Host '--- VERIFY LIVE PIPE ---'
  $livePipe = Connect-LivePipe -PipeName $LivePipeName -TimeoutSeconds $WarmTimeoutSeconds
  try {
    foreach ($cmd in 'STATUS', 'COMPACT') {
      Send-PipeCommand -Pipe $livePipe -Command $cmd | Out-Null
    }
    # `かな' encoded as UTF-8 byte hex.  This read-only request proves that
    # the deployed host has finished loading the immutable local dictionary
    # used for the <=150 ms first-candidate surface. STATUS alone can pass
    # even when that performance path is absent or still empty.
    $preview = Send-PipeCommand -Pipe $livePipe `
      -Command 'PREVIEW e3818be381aa'
    if (-not $DryRun -and $preview -notmatch '^PREVIEW /.+/$') {
      throw "live dictionary preview unavailable: $preview"
    }
  } finally {
    if ($livePipe) { $livePipe.Dispose() }
  }
}

# 7. Sumi UI: replace only the resident Sumi process and start the newly
#    deployed candidate/registration-capable binary detached.
if ($Indicator) {
  Write-Host '--- INDICATOR ---'
  if ($DryRun) {
    Write-Step "would stop existing $IndicatorProcessName processes"
    Write-Step "would start $indicatorDest detached"
  } elseif (Test-Path -LiteralPath $indicatorDest) {
    Get-Process -Name $IndicatorProcessName -ErrorAction SilentlyContinue |
      Stop-Process -Force
    $ipsi = [Diagnostics.ProcessStartInfo]::new()
    $ipsi.FileName = $indicatorDest
    $ipsi.WorkingDirectory = Split-Path -Parent $indicatorDest
    $ipsi.UseShellExecute = $false
    # GApplication's Windows session registration can outlive the process
    # briefly and absorb this freshly deployed launch.  We have already
    # stopped every resident Sumi process above, so bypassing that stale
    # uniqueness check here cannot create a duplicate pill.
    $ipsi.EnvironmentVariables['DDSKK_ALLOW_MULTIPLE_INSTANCES'] = '1'
    $ip = [Diagnostics.Process]::Start($ipsi)
    Write-Host "INDIC : pid=$($ip.Id) $indicatorDest"
  } else {
    Write-Host "INDIC : exe not found ($indicatorDest)"
  }
}

Write-Host "=== done $(if ($DryRun) { '(dry run -- nothing was changed)' }) ==="
if (-not $DryRun) {
  Write-Host "Rollback: powershell -ExecutionPolicy Bypass -File windows\scripts\rollback-live.ps1 -Manifest `"$manifestPath`""
}
# Without this, the script's exit code is whatever the last native/cmdlet
# call left in $LASTEXITCODE (observed: robocopy's success codes 1-7 leaked
# through as apparent failure). Reaching this line means every step above
# either succeeded or threw.
exit 0
