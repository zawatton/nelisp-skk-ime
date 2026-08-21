<#
.SYNOPSIS
  Appends a user-visible defect or its resolution to the active v1 evidence.
#>
[CmdletBinding()]
param(
  [ValidateSet('', 'P0', 'P1', 'P2')][string]$Severity = '',
  [string]$Title = '',
  [string]$Id = '',
  [switch]$Resolve,
  [string]$Note = '',
  [string]$StatusPath = "$env:LOCALAPPDATA\DDSKK\verification\v1-monitor-current.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $StatusPath)) { throw "monitor status not found: $StatusPath" }
$status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
if (-not $status.incident_log) { throw 'active monitor has no incident ledger' }
$ledger = [IO.Path]::GetFullPath([string]$status.incident_log)
if (-not (Test-Path -LiteralPath $ledger)) { throw "incident ledger not found: $ledger" }

$mutex = [Threading.Mutex]::new($false, 'Local\NeLispImeV1IncidentLedger')
$owned = $false
try {
  $owned = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
  if (-not $owned) { throw 'timed out waiting for the incident ledger' }
  $now = Get-Date
  if ($Resolve) {
    if (-not $Id) { throw '-Id is required with -Resolve' }
    $events = @(Get-Content -LiteralPath $ledger | ForEach-Object { $_ | ConvertFrom-Json })
    $prior = @($events | Where-Object {
      $null -ne $_.PSObject.Properties['id'] -and $_.id -eq $Id
    } | Select-Object -Last 1)
    if ($prior.Count -ne 1) { throw "incident not found: $Id" }
    $record = [ordered]@{
      type = 'resolution'; timestamp = $now.ToString('o'); id = $Id
      status = 'resolved'; note = $Note
    }
  } else {
    if (-not $Severity -or -not $Title) { throw '-Severity and -Title are required' }
    if (-not $Id) {
      $Id = '{0}-{1}-{2}' -f $Severity, $now.ToString('yyyyMMdd-HHmmss'),
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    }
    $record = [ordered]@{
      type = 'incident'; timestamp = $now.ToString('o'); id = $Id
      severity = $Severity; status = 'open'; title = $Title; note = $Note
    }
  }
  $record | ConvertTo-Json -Compress | Add-Content -LiteralPath $ledger -Encoding UTF8
  $record | ConvertTo-Json -Depth 3
} finally {
  if ($owned) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
