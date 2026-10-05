# Shared by core-only deployment/rollback and private tests. No process actions.
function Get-NativeImePointer {
  param([string]$Path, [string]$Name)
  $item = if (Test-Path -LiteralPath $Path) { Get-ItemProperty -LiteralPath $Path -ErrorAction Stop } else { $null }
  $property = if ($item) { $item.PSObject.Properties[$Name] } else { $null }
  if ($property) { return [string]$property.Value }
  return $null
}

function Format-NativeImePointer {
  param($Value)
  if ($null -eq $Value) { return '<absent>' }
  return "[$Value]"
}

function New-NativeImeDeploymentComponents {
  param([string]$RegistryKey, [string]$ClsidKey, [string]$RunKey,
        [string]$RunName = 'NeLisp IME Sumi',
        [string]$Dll, [string]$CoreDll, [string]$EngineHost,
        [string]$Repository, [string]$Indicator)
  $writes = @(
    @('DLL', $ClsidKey, '(default)', $Dll),
    @('CoreDll', $RegistryKey, 'CoreDll', $CoreDll),
    @('EngineHost', $RegistryKey, 'EngineHost', $EngineHost),
    @('Repository', $RegistryKey, 'Repository', $Repository),
    @('Indicator', $RegistryKey, 'SettingsExe', $Indicator),
    @('Sumi', $RunKey, $RunName, $(if ($Indicator) { '"' + $Indicator + '"' } else { $null }))
  )
  foreach ($write in $writes) {
    if (-not $write[3]) { continue }
    [pscustomobject]@{ component=$write[0]; path=$write[1]; name=$write[2]
      old=(Get-NativeImePointer $write[1] $write[2]); new=$write[3] }
  }
}

function Get-NativeImeRollbackComponents {
  [CmdletBinding()]
  param($Record,
        [string]$RegistryKey = 'HKCU:\Software\NativeIME',
        [string]$ClsidKey = 'HKCU:\Software\Classes\CLSID\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\InprocServer32',
        [string]$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')
  if ($Record.PSObject.Properties['components']) { return $Record.components }
  $writes = @(@('DLL', $ClsidKey, '(default)', 'dll'),
      @('CoreDll', $RegistryKey, 'CoreDll', 'core'),
      @('EngineHost', $RegistryKey, 'EngineHost', 'engine_host'),
      @('Repository', $RegistryKey, 'Repository', 'repository'),
      @('Indicator', $RegistryKey, 'SettingsExe', 'settings_exe'),
      @('Sumi', $RunKey, 'NeLisp IME Sumi', 'sumi_run'))
  if ($Record.schema -eq 2) {
    $writes = @( ,@('CoreDll', [string]$Record.registry_key, 'CoreDll', 'core'))
  }
  $components = @(foreach ($write in $writes) {
    $property = $Record.previous.PSObject.Properties[$write[3]]
    if ($property) {
      [pscustomobject]@{ component=$write[0]; path=$write[1]; name=$write[2]; old=$property.Value }
    }
  })
  Write-Warning ('Legacy rollback manifest has no component list or deployed-value guard; it would touch: ' +
    (($components | ForEach-Object { "$($_.path)\$($_.name)" }) -join ', '))
  return $components
}

function Restore-NativeImeComponents {
  [CmdletBinding()]
  param([object[]]$Components, [switch]$DryRun, [switch]$Force)
  foreach ($entry in $Components) {
    $live = Get-NativeImePointer $entry.path $entry.name
    $liveLabel = Format-NativeImePointer $live
    $label = "$($entry.path)\$($entry.name)"
    if ($entry.PSObject.Properties['new'] -and -not $Force -and $live -cne $entry.new) {
      Write-Host "SKIP: $label live=$liveLabel, deployment set=$(Format-NativeImePointer $entry.new); use -Force to override"
      continue
    }
    $target = if ($null -eq $entry.old) { '<absent: remove value>' } else { "[$($entry.old)]" }
    if ($DryRun) {
      Write-Host "[DRYRUN] would restore $label from $liveLabel to $target"
    } else {
      if ($null -eq $entry.old) {
        Remove-ItemProperty -LiteralPath $entry.path -Name $entry.name -ErrorAction SilentlyContinue
      } else {
        if ($entry.component -eq 'CoreDll' -and $entry.old -and
            -not (Test-Path -LiteralPath ([string]$entry.old) -PathType Leaf)) {
          throw "previous core missing: $($entry.old)"
        }
        if (-not (Test-Path -LiteralPath $entry.path)) { New-Item -Path $entry.path -Force | Out-Null }
        New-ItemProperty -LiteralPath $entry.path -Name $entry.name -Value ([string]$entry.old) -PropertyType String -Force | Out-Null
      }
      Write-Host "RESTORE: $label from $liveLabel to $target"
    }
    $entry
  }
}

function Publish-NativeImeCore {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$RegistryKey,
        [switch]$DryRun)
  $DestinationRoot = [IO.Path]::GetFullPath($DestinationRoot)
  $directory = Join-Path $DestinationRoot ('core-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
  $destination = Join-Path $directory 'ddskk-ime-core.dll'
  $manifestPath = Join-Path $directory 'rollback.json'
  if ($DryRun) {
    $components = @(New-NativeImeDeploymentComponents -RegistryKey $RegistryKey -CoreDll $destination)
    Write-Host "[DRYRUN] would copy $Source to $destination"
    Write-Host "[DRYRUN] would save CoreDll component to $manifestPath"
    Write-Host "[DRYRUN] would set $RegistryKey\CoreDll from $(Format-NativeImePointer $components[0].old) to [$destination] (no process restart)"
    return
  }
  $Source = [IO.Path]::GetFullPath($Source)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "core DLL not found: $Source" }
  Get-Item -LiteralPath $RegistryKey -ErrorAction Stop | Out-Null
  New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -ErrorAction Stop
  $components = @(New-NativeImeDeploymentComponents -RegistryKey $RegistryKey -CoreDll $destination)
  $record = [ordered]@{ schema=2; core_only=$true; registry_key=$RegistryKey
    created_at=(Get-Date).ToString('o'); core=$destination; previous=@{core=$components[0].old}; components=$components }
  $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  # Publish only after the immutable file and rollback manifest are complete.
  New-ItemProperty -LiteralPath $RegistryKey -Name CoreDll -Value $destination -PropertyType String -Force | Out-Null
  Write-Host "CORE: $destination (running applications swap when idle)"
  [pscustomobject]@{CoreDll=$destination; Manifest=$manifestPath}
}
function Restore-NativeImeCore {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Record, [switch]$DryRun, [switch]$Force)
  if ($Record.schema -ne 2 -or -not $Record.core_only -or -not $Record.registry_key -or
      $null -eq $Record.previous) { throw 'unsupported core rollback manifest' }
  $components = @(Get-NativeImeRollbackComponents -Record $Record)
  $restored = @(Restore-NativeImeComponents -Components $components -DryRun:$DryRun -Force:$Force)
  $action = if ($DryRun) { 'would_restore' } else { 'restored' }
  Write-Host "CORE ROLLBACK: $action=$($restored.Count) (no process restart)"
}
