param([ValidateSet('deploy','rollback')][string]$Action, [string]$CoreSource)
$ErrorActionPreference = 'Stop'
if (-not $env:NATIVEIME_REGISTRY_KEY.StartsWith('Software\NativeIME-test-')) {
  throw 'Core deployment test requires a private registry key'
}
. (Join-Path $PSScriptRoot '../scripts/core-deployment.ps1')
$key = 'HKCU:\' + $env:NATIVEIME_REGISTRY_KEY
$marker = Join-Path $env:LOCALAPPDATA 'core-test-manifest.json'
if ($Action -eq 'deploy') {
  $published = Publish-NativeImeCore -Source $CoreSource `
    -DestinationRoot (Join-Path $env:LOCALAPPDATA 'DDSKK') -RegistryKey $key
  @{Manifest=$published.Manifest} | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
} else {
  $manifest = (Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json).Manifest
  Restore-NativeImeCore -Record (Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json)
}
