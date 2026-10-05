# Shared by core-only deployment/rollback and private tests. No process actions.
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
    Write-Host "[DRYRUN] would copy $Source to $destination"
    Write-Host "[DRYRUN] would save previous $RegistryKey\CoreDll to $manifestPath"
    Write-Host "[DRYRUN] would set $RegistryKey\CoreDll = $destination (no process restart)"
    return
  }
  $Source = [IO.Path]::GetFullPath($Source)
  if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "core DLL not found: $Source" }
  $item = Get-ItemProperty -LiteralPath $RegistryKey -ErrorAction Stop
  $property = $item.PSObject.Properties['CoreDll']
  $previous = if ($property) { [string]$property.Value } else { $null }
  New-Item -ItemType Directory -Path $directory -ErrorAction Stop | Out-Null
  Copy-Item -LiteralPath $Source -Destination $destination -ErrorAction Stop
  $record = [ordered]@{ schema=2; core_only=$true; registry_key=$RegistryKey
    created_at=(Get-Date).ToString('o'); core=$destination; previous=@{core=$previous} }
  $record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  # Publish only after the immutable file and rollback manifest are complete.
  New-ItemProperty -LiteralPath $RegistryKey -Name CoreDll -Value $destination -PropertyType String -Force | Out-Null
  Write-Host "CORE: $destination (running applications swap when idle)"
  [pscustomobject]@{CoreDll=$destination; Manifest=$manifestPath}
}
function Restore-NativeImeCore {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Record, [switch]$DryRun)
  if ($Record.schema -ne 2 -or -not $Record.core_only -or -not $Record.registry_key -or
      $null -eq $Record.previous) { throw 'unsupported core rollback manifest' }
  $key = [string]$Record.registry_key
  $previous = $Record.previous.core
  if ($DryRun) { Write-Host "[DRYRUN] would restore $key\CoreDll = $previous (no process restart)"; return }
  if ([string]::IsNullOrEmpty([string]$previous)) {
    Remove-ItemProperty -LiteralPath $key -Name CoreDll -ErrorAction SilentlyContinue
  } else {
    if (-not (Test-Path -LiteralPath ([string]$previous) -PathType Leaf)) { throw "previous core missing: $previous" }
    New-ItemProperty -LiteralPath $key -Name CoreDll -Value ([string]$previous) -PropertyType String -Force | Out-Null
  }
  Write-Host 'CORE ROLLBACK: PASS (no process restart)'
}
