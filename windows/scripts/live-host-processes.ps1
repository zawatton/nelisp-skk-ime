# Shared deployment/rollback host selection. Never infer ownership from the
# process name, command line, or the deployment shell's pipe environment.
# Outside-root hosts are protected even if configured to use the live pipe.
function ConvertTo-LiveHostPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
  $Path = $Path.Replace('/', '\')
  if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
    $Path = '\\' + $Path.Substring(8)
  } elseif ($Path.StartsWith('\\?\')) { $Path = $Path.Substring(4) }
  # Reject relative and drive-relative paths instead of resolving against cwd.
  if ($Path -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)') { return $null }
  try { return [IO.Path]::GetFullPath($Path).TrimEnd('\') }
  catch { return $null }
}

function Select-LiveHostProcess {
  param([AllowEmptyCollection()][object[]]$Processes, [Parameter(Mandatory)][string]$LiveRoot)
  $root = ConvertTo-LiveHostPath $LiveRoot
  if (-not $root) { throw "Invalid absolute live deployment root: $LiveRoot" }
  foreach ($process in $Processes) {
    if ($process.Name -ine 'ddskk-engine-host.exe') { continue }
    $path = ConvertTo-LiveHostPath $process.ExecutablePath
    if ($path -and $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($path) -ieq 'ddskk-engine-host.exe') {
      [pscustomobject]@{
        ProcessId = $process.ProcessId
        ExecutablePath = $path
        Reason = "executable under live deployment root $root"
      }
    }
  }
}

function Stop-DdskkLiveHost {
  param([Parameter(Mandatory)][string]$LiveRoot, [switch]$DryRun)
  # Get-Process avoids requiring WMI/CIM access. Unreadable executable paths
  # fail closed; do not replace them with registry or environment guesses.
  $hosts = @(Get-Process -ErrorAction Stop | Where-Object ProcessName -eq 'ddskk-engine-host')
  $selectedCount = 0
  foreach ($hostProcess in $hosts) {
    $path = $null
    try { $path = $hostProcess.MainModule.FileName } catch { }
    $record = [pscustomobject]@{
      Name = 'ddskk-engine-host.exe'; ProcessId = $hostProcess.Id; ExecutablePath = $path
    }
    $selected = @(Select-LiveHostProcess -Processes @($record) -LiveRoot $LiveRoot)
    if ($selected.Count -eq 0) {
      $reason = if ($path) { 'executable outside live deployment root' } else { 'executable path unavailable; ownership unproven' }
      Write-Host "KEEP  : pid=$($hostProcess.Id) path=$path reason=$reason"
      continue
    }
    $selectedCount++
    $detail = "pid=$($selected[0].ProcessId) path=$($selected[0].ExecutablePath) reason=$($selected[0].Reason)"
    if ($DryRun) { Write-Host "[DRYRUN] would stop $detail"; continue }
    # Kill through the original Process object's handle, not a fresh PID
    # lookup that could hit a different process after PID reuse.
    [void]$hostProcess.Handle
    if (-not $hostProcess.HasExited) {
      Write-Host "STOP  : $detail"
      $hostProcess.Kill()
      if (-not $hostProcess.WaitForExit(5000)) { throw "Host did not stop: $detail" }
    }
  }
  $prefix = if ($DryRun) { '[DRYRUN] ' } else { '' }
  Write-Host "${prefix}live host selection: selected=$selectedCount inspected=$($hosts.Count)"
  if (-not $DryRun) { Start-Sleep -Milliseconds 400 }
}
