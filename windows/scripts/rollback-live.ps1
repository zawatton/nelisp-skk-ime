<#
.SYNOPSIS
  Restores the exact NeLisp IME runtime pointers saved by deploy-live.ps1.

.DESCRIPTION
  No deployed directory is overwritten or deleted. Registry pointers are
  restored from rollback.json, the prior engine host is restarted and checked
  over the live pipe, and the prior Sumi executable is relaunched.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Manifest,
  [switch]$DryRun,
  [int]$WarmTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Manifest = [IO.Path]::GetFullPath($Manifest)
if (-not (Test-Path -LiteralPath $Manifest)) { throw "manifest not found: $Manifest" }
$record = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($record.schema -ne 1 -or $null -eq $record.previous) {
  throw "unsupported rollback manifest: $Manifest"
}

$nativeImeKey = 'HKCU:\Software\NativeIME'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'NeLisp IME Sumi'
$clsidKey = 'HKCU:\Software\Classes\CLSID\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\InprocServer32'

function Show-Or-Set {
  param([string]$Path, [string]$Name, $Value)
  $label = if ($Name -eq '(default)') { "$Path (default)" } else { "$Path\$Name" }
  if ($DryRun) { Write-Host "[DRYRUN] would restore $label = $Value"; return }
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
  } else {
    Set-ItemProperty -Path $Path -Name $Name -Value ([string]$Value)
  }
  Write-Host "RESTORE: $label = $Value"
}

Show-Or-Set $clsidKey '(default)' $record.previous.dll
Show-Or-Set $nativeImeKey 'EngineHost' $record.previous.engine_host
Show-Or-Set $nativeImeKey 'Repository' $record.previous.repository
Show-Or-Set $nativeImeKey 'SettingsExe' $record.previous.settings_exe
Show-Or-Set $runKey $runName $record.previous.sumi_run

if ($DryRun) {
  Write-Host '[DRYRUN] would restart only ddskk-engine-host.exe and sumi-skk-ui.exe'
  Write-Host '[DRYRUN] would verify STATUS on \\.\pipe\ddskk-ime-v1'
  exit 0
}

Get-CimInstance Win32_Process -Filter "Name='ddskk-engine-host.exe'" |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -Confirm:$false -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 400
foreach ($name in 'DDSKK_PIPE_NAME','DDSKK_USER_JISYO',
                  'DDSKK_USER_JISYO_SAVE_BATCH_SIZE','DDSKK_ENGINE_IDLE_GC_MS') {
  Remove-Item "Env:\$name" -ErrorAction SilentlyContinue
}

$nelispExe = (Get-ItemProperty -Path $nativeImeKey).EngineExecutable
$psi = [Diagnostics.ProcessStartInfo]::new()
$psi.FileName = [string]$record.previous.engine_host
$psi.Arguments = '"{0}" "{1}"' -f $nelispExe, [string]$record.previous.repository
$psi.WorkingDirectory = [string]$record.previous.repository
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

Get-Process -Name 'sumi-skk-ui' -ErrorAction SilentlyContinue | Stop-Process -Force
if ($record.previous.settings_exe -and
    (Test-Path -LiteralPath ([string]$record.previous.settings_exe))) {
  $sumiPsi = [Diagnostics.ProcessStartInfo]::new()
  $sumiPsi.FileName = [string]$record.previous.settings_exe
  $sumiPsi.WorkingDirectory = Split-Path -Parent ([string]$record.previous.settings_exe)
  $sumiPsi.UseShellExecute = $false
  $sumiPsi.EnvironmentVariables['DDSKK_ALLOW_MULTIPLE_INSTANCES'] = '1'
  $sumi = [Diagnostics.Process]::Start($sumiPsi)
  Write-Host "START : Sumi pid=$($sumi.Id)"
}

Write-Host 'ROLLBACK: PASS'
Write-Host 'NOTE: restart applications that already loaded ddskk-ime.dll.'
