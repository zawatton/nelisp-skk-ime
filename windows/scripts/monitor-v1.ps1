<#
.SYNOPSIS
  Records the elapsed 24-hour soak and seven-day normal-use release evidence.

.DESCRIPTION
  Read-only monitor: it never sends engine requests or changes the live IME.
  Once per interval it records the versioned runtime paths, process identities,
  and private memory as JSON Lines. PID/path changes, missing processes, or a
  process above the memory ceiling are recorded as failures. The 24-hour soak
  milestone requires 24 hours of actual samples (sleep time does not count);
  the normal-use milestone requires seven wall-clock days.
#>
[CmdletBinding()]
param(
  [int]$SampleSeconds = 60,
  [int]$SoakHours = 24,
  [int]$NormalUseDays = 7,
  [int]$MemoryLimitMiB = 768,
  [string]$OutputDirectory = "$env:LOCALAPPDATA\DDSKK\verification",
  [int]$MaxSamples = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($SampleSeconds -lt 10 -or $SoakHours -lt 1 -or $NormalUseDays -lt 1) {
  throw 'invalid monitor duration'
}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $OutputDirectory "v1-monitor-$stamp.jsonl"
$statusPath = Join-Path $OutputDirectory 'v1-monitor-current.json'
$native = Get-ItemProperty 'HKCU:\Software\NativeIME'
$expectedHost = [IO.Path]::GetFullPath([string]$native.EngineHost)
$expectedRepository = [IO.Path]::GetFullPath([string]$native.Repository)
$expectedSumi = [IO.Path]::GetFullPath([string]$native.SettingsExe)
$expectedDll = [IO.Path]::GetFullPath([string](Get-ItemProperty `
  'HKCU:\Software\Classes\CLSID\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\InprocServer32').'(default)')
$appMatrix = [ordered]@{
  notepad = $false
  edge = $false
  terminal = $false
  emacs = $false
}
$started = Get-Date
$wallDeadline = $started.AddDays($NormalUseDays)
$soakSamplesNeeded = [Math]::Ceiling(($SoakHours * 3600) / $SampleSeconds)
$samples = 0
$failures = 0
$initialHostPid = $null
$initialChildPid = $null
$maxHostBytes = 0L
$maxChildBytes = 0L
$maxSumiBytes = 0L
$soakRecorded = $false

function Write-Record($Record) {
  $Record | ConvertTo-Json -Compress -Depth 5 |
    Add-Content -LiteralPath $logPath -Encoding UTF8
}

Write-Record ([ordered]@{
  type = 'start'; timestamp = $started.ToString('o'); schema = 1
  expected_host = $expectedHost; expected_repository = $expectedRepository
  expected_sumi = $expectedSumi; expected_dll = $expectedDll
  sample_seconds = $SampleSeconds
  soak_hours = $SoakHours; normal_use_days = $NormalUseDays
  memory_limit_mib = $MemoryLimitMiB
})

while ((Get-Date) -lt $wallDeadline -or $samples -lt $soakSamplesNeeded) {
  $now = Get-Date
  $hostCim = @(Get-CimInstance Win32_Process -Filter "Name='ddskk-engine-host.exe'" |
    Where-Object { $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -eq $expectedHost })
  $sumiCim = @(Get-CimInstance Win32_Process -Filter "Name='sumi-skk-ui.exe'" |
    Where-Object { $_.ExecutablePath -and
      [IO.Path]::GetFullPath($_.ExecutablePath) -eq $expectedSumi })
  $hostPid = if ($hostCim.Count -eq 1) { [int]$hostCim[0].ProcessId } else { $null }
  $childCim = @(if ($null -ne $hostPid) {
    Get-CimInstance Win32_Process | Where-Object {
      $_.ParentProcessId -eq $hostPid -and $_.Name -eq 'nelisp.exe' }
  })
  $childPid = if ($childCim.Count -eq 1) { [int]$childCim[0].ProcessId } else { $null }
  $sumiPid = if ($sumiCim.Count -eq 1) { [int]$sumiCim[0].ProcessId } else { $null }

  if ($null -eq $initialHostPid -and $null -ne $hostPid) { $initialHostPid = $hostPid }
  if ($null -eq $initialChildPid -and $null -ne $childPid) { $initialChildPid = $childPid }
  $hostBytes = if ($null -ne $hostPid) { (Get-Process -Id $hostPid).PrivateMemorySize64 } else { 0L }
  $childBytes = if ($null -ne $childPid) { (Get-Process -Id $childPid).PrivateMemorySize64 } else { 0L }
  $sumiBytes = if ($null -ne $sumiPid) { (Get-Process -Id $sumiPid).PrivateMemorySize64 } else { 0L }
  $maxHostBytes = [Math]::Max($maxHostBytes, $hostBytes)
  $maxChildBytes = [Math]::Max($maxChildBytes, $childBytes)
  $maxSumiBytes = [Math]::Max($maxSumiBytes, $sumiBytes)
  $limitBytes = [int64]$MemoryLimitMiB * 1MB

  # Actual application evidence, not just synthetic client names: record once
  # each required executable has loaded this exact versioned COM DLL. Existing
  # processes may legitimately retain an older in-process DLL until the user
  # next restarts them; the matrix fills naturally during the seven-day run.
  $appProcesses = @{
    notepad = @(Get-Process -Name 'Notepad' -ErrorAction SilentlyContinue)
    edge = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue)
    terminal = @(Get-Process -Name 'WindowsTerminal' -ErrorAction SilentlyContinue)
    emacs = @(Get-Process -Name 'emacs' -ErrorAction SilentlyContinue)
  }
  foreach ($appName in @('notepad','edge','terminal','emacs')) {
    if ($appMatrix[$appName]) { continue }
    foreach ($appProcess in $appProcesses[$appName]) {
      try {
        $loaded = @($appProcess.Modules | Where-Object {
          $_.ModuleName -eq 'ddskk-ime.dll' -and
          [IO.Path]::GetFullPath($_.FileName) -eq $expectedDll })
        if ($loaded.Count -gt 0) { $appMatrix[$appName] = $true; break }
      } catch {}
    }
  }
  $issues = @()
  if ($hostCim.Count -ne 1) { $issues += "host-count=$($hostCim.Count)" }
  if ($childCim.Count -ne 1) { $issues += "child-count=$($childCim.Count)" }
  if ($sumiCim.Count -ne 1) { $issues += "sumi-count=$($sumiCim.Count)" }
  if ($hostCim.Count -eq 1 -and
      [string]$hostCim[0].CommandLine -notlike "*$expectedRepository*") {
    $issues += 'host-repository-mismatch'
  }
  $currentNative = Get-ItemProperty 'HKCU:\Software\NativeIME'
  if ([IO.Path]::GetFullPath([string]$currentNative.EngineHost) -ne $expectedHost) {
    $issues += 'registry-host-changed'
  }
  if ([IO.Path]::GetFullPath([string]$currentNative.Repository) -ne $expectedRepository) {
    $issues += 'registry-repository-changed'
  }
  if ([IO.Path]::GetFullPath([string]$currentNative.SettingsExe) -ne $expectedSumi) {
    $issues += 'registry-sumi-changed'
  }
  if ($null -ne $initialHostPid -and $hostPid -ne $initialHostPid) { $issues += 'host-pid-changed' }
  if ($null -ne $initialChildPid -and $childPid -ne $initialChildPid) { $issues += 'child-pid-changed' }
  if ($hostBytes -gt $limitBytes) { $issues += 'host-memory-limit' }
  if ($childBytes -gt $limitBytes) { $issues += 'child-memory-limit' }
  if ($sumiBytes -gt $limitBytes) { $issues += 'sumi-memory-limit' }
  if ($issues.Count -gt 0) { $failures++ }
  $samples++
  Write-Record ([ordered]@{
    type = 'sample'; timestamp = $now.ToString('o'); sample = $samples
    host_pid = $hostPid; child_pid = $childPid; sumi_pid = $sumiPid
    host_private_bytes = $hostBytes; child_private_bytes = $childBytes
    sumi_private_bytes = $sumiBytes; issues = $issues
    app_matrix = $appMatrix
  })

  if (-not $soakRecorded -and $samples -ge $soakSamplesNeeded) {
    $soakRecorded = $true
    Write-Record ([ordered]@{
      type = 'soak-milestone'; timestamp = $now.ToString('o')
      active_sample_hours = [Math]::Round(($samples * $SampleSeconds) / 3600, 3)
      failures = $failures; max_host_bytes = $maxHostBytes
      max_child_bytes = $maxChildBytes; max_sumi_bytes = $maxSumiBytes
      pass = ($failures -eq 0)
    })
  }
  ([ordered]@{
    log = $logPath; started = $started.ToString('o'); last_sample = $now.ToString('o')
    samples = $samples; failures = $failures; soak_complete = $soakRecorded
    normal_use_complete = ($now -ge $wallDeadline)
    app_matrix = $appMatrix
    max_host_bytes = $maxHostBytes; max_child_bytes = $maxChildBytes
    max_sumi_bytes = $maxSumiBytes
  }) | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $statusPath -Encoding UTF8
  if ($MaxSamples -gt 0 -and $samples -ge $MaxSamples) { break }
  Start-Sleep -Seconds $SampleSeconds
}

$finished = Get-Date
$appMatrixComplete = -not ($appMatrix.Values -contains $false)
Write-Record ([ordered]@{
  type = 'complete'; timestamp = $finished.ToString('o'); samples = $samples
  failures = $failures; soak_complete = $soakRecorded
  normal_use_complete = ($finished -ge $wallDeadline)
  app_matrix = $appMatrix; app_matrix_complete = $appMatrixComplete
  max_host_bytes = $maxHostBytes; max_child_bytes = $maxChildBytes
  max_sumi_bytes = $maxSumiBytes; test_run = ($MaxSamples -gt 0)
  pass = ($failures -eq 0 -and $appMatrixComplete)
})
exit $(if ($failures -eq 0) { 0 } else { 1 })
