<#
.SYNOPSIS
  Restores only the NeLisp IME runtime pointers changed by a deployment.

.DESCRIPTION
  No deployed directory is overwritten or deleted. Registry pointers are
  restored from rollback.json if still equal to the deployment's new value.
  -Force overrides that check. Host and Sumi restarts occur only when their
  pointers are restored. Legacy manifests warn and retain unguarded restoration.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Manifest,
  [switch]$DryRun,
  [switch]$Force,
  [int]$WarmTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'live-host-processes.ps1')
. (Join-Path $PSScriptRoot 'core-deployment.ps1')
$Manifest = [IO.Path]::GetFullPath($Manifest)
if (-not (Test-Path -LiteralPath $Manifest)) { throw "manifest not found: $Manifest" }
$record = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($record.schema -eq 2) {
  Restore-NativeImeCore -Record $record -DryRun:$DryRun -Force:$Force
  exit 0
}

if ($record.schema -ne 1 -or
    (-not $record.PSObject.Properties['components'] -and -not $record.PSObject.Properties['previous'])) {
  throw "unsupported rollback manifest: $Manifest"
}

$nativeImeKey = 'HKCU:\Software\NativeIME'
$components = @(Get-NativeImeRollbackComponents -Record $record)
$restored = @(Restore-NativeImeComponents -Components $components -DryRun:$DryRun -Force:$Force)
$restartHost = @($restored | Where-Object { $_.component -in @('EngineHost', 'Repository') }).Count -gt 0
$restartIndicator = @($restored | Where-Object { $_.component -eq 'Indicator' }).Count -gt 0
if ($DryRun) {
  if ($restartHost) {
    Stop-DdskkLiveHost -LiveRoot (Join-Path $env:LOCALAPPDATA 'DDSKK') -DryRun
    Write-Host '[DRYRUN] would start host using the resulting EngineHost/Repository and verify STATUS on \\.\pipe\ddskk-ime-v1'
  }
  if ($restartIndicator) { Write-Host '[DRYRUN] would restart sumi-skk-ui.exe using the resulting SettingsExe' }
  exit 0
}

if ($restartHost) {
Stop-DdskkLiveHost -LiveRoot (Join-Path $env:LOCALAPPDATA 'DDSKK')
foreach ($name in 'DDSKK_PIPE_NAME','DDSKK_USER_JISYO',
                  'DDSKK_USER_JISYO_SAVE_BATCH_SIZE','DDSKK_ENGINE_IDLE_GC_MS') {
  Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
}

$nelispExe = (Get-ItemProperty -Path $nativeImeKey).EngineExecutable
$liveSettings = Get-ItemProperty -Path $nativeImeKey
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = [string]$liveSettings.EngineHost
$psi.Arguments = '"{0}" "{1}"' -f $nelispExe, [string]$liveSettings.Repository
$psi.WorkingDirectory = [string]$liveSettings.Repository
$psi.UseShellExecute = $false
$hostProcess = [Diagnostics.Process]::Start($psi)
Write-Host "START : host pid=$($hostProcess.Id)"

$deadline = (Get-Date).AddSeconds($WarmTimeoutSeconds)
$pipe = $null
while ((Get-Date) -lt $deadline -and $null -eq $pipe) {
  try {
    $candidate = [IO.Pipes.NamedPipeClientStream]::new('.', 'ddskk-ime-v1',
      [IO.Pipes.PipeDirection]::InOut)
    $candidate.Connect(500)
    $candidate.ReadMode = [IO.Pipes.PipeTransmissionMode]::Message
    $pipe = $candidate
  } catch { Start-Sleep -Milliseconds 250 }
}
if ($null -eq $pipe) { throw 'restored host did not open the live pipe' }
try {
  $request = [Text.Encoding]::ASCII.GetBytes("STATUS`n")
  $pipe.Write($request, 0, $request.Length)
  $pipe.Flush()
  $buffer = [byte[]]::new(8192)
  $count = $pipe.Read($buffer, 0, $buffer.Length)
  $reply = [Text.Encoding]::ASCII.GetString($buffer, 0, $count).Trim()
  if (-not $reply.StartsWith('STATE ')) { throw "unexpected STATUS reply: $reply" }
  Write-Host "VERIFY: $reply"
} finally { $pipe.Dispose() }
}

if ($restartIndicator) {
Get-Process -Name 'sumi-skk-ui' -ErrorAction SilentlyContinue | Stop-Process -Force
$settingsExe = Get-NativeImePointer $nativeImeKey 'SettingsExe'
if ($settingsExe -and (Test-Path -LiteralPath $settingsExe)) {
  $sumiPsi = [Diagnostics.ProcessStartInfo]::new()
  $sumiPsi.FileName = $settingsExe
  $sumiPsi.WorkingDirectory = Split-Path -Parent $settingsExe
  $sumiPsi.UseShellExecute = $false
  $sumiPsi.EnvironmentVariables['DDSKK_ALLOW_MULTIPLE_INSTANCES'] = '1'
  $sumi = [Diagnostics.Process]::Start($sumiPsi)
  Write-Host "START : Sumi pid=$($sumi.Id)"
}
}

Write-Host 'ROLLBACK: PASS'
Write-Host 'NOTE: restart applications that already loaded ddskk-ime.dll.'
