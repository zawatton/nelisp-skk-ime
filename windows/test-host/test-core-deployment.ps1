[CmdletBinding()]
param([Parameter(Mandatory)][string]$CoreDllPath,
      [Parameter(Mandatory)][string]$ArtifactDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/core-deployment.ps1')
$key = 'HKCU:\Software\NativeIME-test-' + [guid]::NewGuid().ToString('N')
$destination = Join-Path ([IO.Path]::GetFullPath($ArtifactDirectory)) 'deploy-test'
$CoreDllPath = [IO.Path]::GetFullPath($CoreDllPath)
$assertions = 0
function Require([bool]$condition, [string]$message) { if (-not $condition) { throw $message }; $script:assertions++ }
try {
  New-Item -Path $key -Force | Out-Null
  New-ItemProperty -Path $key -Name CoreDll -Value $CoreDllPath -PropertyType String | Out-Null
  New-ItemProperty -Path $key -Name EngineHost -Value 'unchanged-sentinel' -PropertyType String | Out-Null
  $published = Publish-NativeImeCore -Source $CoreDllPath -DestinationRoot $destination -RegistryKey $key
  Require ((Get-ItemProperty -Path $key).CoreDll -eq $published.CoreDll) 'Core pointer was not published'
  Require ((Get-FileHash -LiteralPath $CoreDllPath).Hash -eq (Get-FileHash -LiteralPath $published.CoreDll).Hash) 'Copied core differs'
  Require ((Get-ItemProperty -Path $key).EngineHost -eq 'unchanged-sentinel') 'Deployment touched host pointer'
  $record = Get-Content -LiteralPath $published.Manifest -Raw | ConvertFrom-Json
  Restore-NativeImeCore -Record $record
  Require ((Get-ItemProperty -Path $key).CoreDll -eq $CoreDllPath) 'Rollback did not restore A'
  Require ((Get-ItemProperty -Path $key).EngineHost -eq 'unchanged-sentinel') 'Rollback touched host pointer'
  Remove-ItemProperty -Path $key -Name CoreDll
  $published = Publish-NativeImeCore -Source $CoreDllPath -DestinationRoot $destination -RegistryKey $key
  Restore-NativeImeCore -Record (Get-Content -LiteralPath $published.Manifest -Raw | ConvertFrom-Json)
  Require ($null -eq (Get-ItemProperty -Path $key).PSObject.Properties['CoreDll']) 'Rollback did not restore absent value'
  foreach ($name in @('deploy-live.ps1','rollback-live.ps1','core-deployment.ps1')) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../scripts/$name"), [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) "Parse errors in $name"
  }
  Write-Output "PASS core deployment/rollback helpers assertions=$assertions private_key=True wrapper_scripts_executed=False"
} finally { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
