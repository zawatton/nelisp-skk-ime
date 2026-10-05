[CmdletBinding()]
param([string]$ArtifactDirectory)
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $PSScriptRoot '../../build/ds2-rollback' }
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../scripts/core-deployment.ps1')
$key = 'HKCU:\Software\NativeIME-test-' + [guid]::NewGuid().ToString('N')
$root = [IO.Path]::GetFullPath($ArtifactDirectory)
$assertions = 0
function Require([bool]$condition, [string]$message) {
  if (-not $condition) { throw $message }
  $script:assertions++
}
# Extract only pointer/manifest blocks, never invoke either live wrapper.
$deployPath = Join-Path $PSScriptRoot '../scripts/deploy-live.ps1'
$rollbackPath = Join-Path $PSScriptRoot '../scripts/rollback-live.ps1'
$deployText = Get-Content -LiteralPath $deployPath -Raw
$rollbackText = Get-Content -LiteralPath $rollbackPath -Raw
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($deployPath, [ref]$tokens, [ref]$errors)
foreach ($name in 'Write-Step', 'Set-NativeImeValue', 'Set-ClsidDefault') {
  $definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
  }, $true)
  . ([scriptblock]::Create($definition.Extent.Text))
}
$start = $deployText.IndexOf('$manifestDir =')
$end = $deployText.IndexOf('# 6. Restart', $start)
$deployPointers = [scriptblock]::Create($deployText.Substring($start, $end - $start))
$start = $rollbackText.IndexOf('$components =')
$end = $rollbackText.IndexOf('if ($DryRun)', $start)
$rollbackPointers = [scriptblock]::Create($rollbackText.Substring($start, $end - $start))
try {
  New-Item -ItemType Directory -Force $root | Out-Null
  $source = Join-Path $root 'fixture-core.dll'
  Set-Content -LiteralPath $source -Value 'private test fixture'
  New-Item -Path $key -Force | Out-Null
  New-ItemProperty -Path $key -Name CoreDll -Value $source -PropertyType String | Out-Null
  $a = Publish-NativeImeCore -Source $source -DestinationRoot $root -RegistryKey $key
  $b = Publish-NativeImeCore -Source $source -DestinationRoot $root -RegistryKey $key
  $record = Get-Content -LiteralPath $a.Manifest -Raw | ConvertFrom-Json
  Restore-NativeImeCore -Record $record
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $b.CoreDll) 'FAIL: stale core rollback overwrote later deployment (expected skip)'

  $output = @(Restore-NativeImeCore -Record $record -DryRun -Force 6>&1) -join "`n"
  Require ($output.Contains('would restore') -and $output.Contains($b.CoreDll) -and $output.Contains($source)) 'Forced dry run must show live and target values'
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $b.CoreDll) 'Forced dry run wrote registry'
  $output = @(Restore-NativeImeCore -Record $record -DryRun 6>&1) -join "`n"
  Require ($output.Contains('SKIP:') -and $output.Contains('-Force')) 'Stale dry run must explain skip and override'
  Restore-NativeImeCore -Record $record -Force
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $source) 'Force did not restore old core'

  # Host-only deployment runs the actual manifest and registry write block.
  $NativeImeKey = $key
  $ClsidKey = Join-Path $key 'InprocServer32'
  $UserRunKey = Join-Path $key 'Run'
  $SumiRunValue = 'NeLisp IME Sumi'
  New-Item -Path $ClsidKey -Force | Out-Null
  New-Item -Path $UserRunKey -Force | Out-Null
  New-ItemProperty -Path $key -Name EngineHost -Value 'old-host' -PropertyType String | Out-Null
  New-ItemProperty -Path $key -Name Repository -Value 'old-repo' -PropertyType String | Out-Null
  $Dll = $false; $HostExe = $true; $Engine = $false; $Indicator = $false
  $DryRun = $false; $Force = $false
  $BinDir = Join-Path $root 'host-deploy'
  $SnapshotRoot = Join-Path $root 'snapshot'
  $dllDest = $null; $hostDest = 'new-host'; $snapshotDir = $null; $indicatorDest = $null
  . $deployPointers
  $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  Require ($record.components.Count -eq 1 -and $record.components[0].component -eq 'EngineHost') 'Host manifest captured unrelated components'
  Require ($record.components[0].old -ceq 'old-host' -and $record.components[0].new -ceq 'new-host') 'Host manifest lacks exact old/new'
  $core = Publish-NativeImeCore -Source $source -DestinationRoot $root -RegistryKey $key
  . $rollbackPointers
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $core.CoreDll) 'Host rollback touched later CoreDll'
  Require ((Get-ItemProperty -LiteralPath $key).EngineHost -ceq 'old-host') 'Host rollback did not restore host'
  Require ($restartHost -and -not $restartIndicator) 'Host rollback restart selection incorrect'

  # A combined host/engine deploy must also omit CoreDll, including partial skips.
  $HostExe = $true; $Engine = $true; $snapshotDir = 'new-repo'
  . $deployPointers
  $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  Require ($record.components.Count -eq 2) 'Host+engine manifest includes unrelated values'
  Set-ItemProperty -LiteralPath $key -Name EngineHost -Value 'later-host'
  . $rollbackPointers
  Require ((Get-ItemProperty -LiteralPath $key).EngineHost -ceq 'later-host') 'Host rollback overwrote later host'
  Require ((Get-ItemProperty -LiteralPath $key).Repository -ceq 'old-repo') 'Repository rollback failed'
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $core.CoreDll) 'Combined rollback touched core'
  . $rollbackPointers
  Require ($restored.Count -eq 0 -and -not $restartHost -and -not $restartIndicator) 'Skipped rollback must not restart processes'
  $Force = $true
  . $rollbackPointers
  Require ((Get-ItemProperty -LiteralPath $key).EngineHost -ceq 'old-host') 'Full rollback Force did not override later host'
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $core.CoreDll) 'Full rollback Force touched unlisted core'
  $Force = $false

  # Every selected component (including DLL-associated core and Sumi autorun).
  $Dll = $true; $Indicator = $true
  $dllDest = 'new-dll'; $indicatorDest = 'new-indicator'
  $DryRun = $true
  $before = Get-Content -LiteralPath $manifestPath -Raw
  $output = @(. $deployPointers 6>&1) -join "`n"
  Require ($components.Count -eq 6) 'Full deployment must record all six writes'
  foreach ($entry in $components) {
    Require ($output.Contains("$($entry.path)\$($entry.name) from $(Format-NativeImePointer $entry.old) to [$($entry.new)]")) "Deploy dry run missing exact change: $($entry.component)"
  }
  Require ((Get-Content -LiteralPath $manifestPath -Raw) -ceq $before) 'Deploy dry run wrote manifest'
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $core.CoreDll) 'Deploy dry run wrote core'
  $DryRun = $false
  . $deployPointers
  $record = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $DryRun = $true
  $output = @(. $rollbackPointers 6>&1) -join "`n"
  Require ($restored.Count -eq 6 -and $restartHost -and $restartIndicator) 'Full rollback dry run restart selection incorrect'
  Require ($output.Contains('<absent: remove value>')) 'Dry run must show deletion of formerly absent values'
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $coreDest) 'Rollback dry run wrote core'
  $DryRun = $false
  . $rollbackPointers
  Require ((Get-ItemProperty -LiteralPath $key).CoreDll -ceq $core.CoreDll) 'Full rollback did not restore core'
  Require ($null -eq (Get-ItemProperty -LiteralPath $key).PSObject.Properties['SettingsExe']) 'Rollback did not remove absent indicator'
  Require ($null -eq (Get-ItemProperty -LiteralPath $UserRunKey).PSObject.Properties[$SumiRunValue]) 'Rollback did not remove absent autorun'

  # Legacy schemas retain their broad behavior, but enumerate every affected value.
  $legacy = [pscustomobject]@{ schema=1; previous=[pscustomobject]@{
    dll=$null; core=$source; engine_host='legacy-host'; repository='legacy-repo'; settings_exe=''; sumi_run=$null
  } }
  $warnings = @()
  $legacyComponents = @(Get-NativeImeRollbackComponents -Record $legacy -RegistryKey $key -ClsidKey $ClsidKey -RunKey $UserRunKey -WarningVariable warnings -WarningAction SilentlyContinue)
  Require ($warnings.Count -eq 1 -and $legacyComponents.Count -eq 6) 'Legacy manifest warning or write set missing'
  foreach ($entry in $legacyComponents) {
    Require ([string]$warnings[0] -like "*$($entry.path)\$($entry.name)*") 'Legacy warning omits a touched value'
  }
  $preview = @(Restore-NativeImeComponents -Components $legacyComponents -DryRun 6>&1)
  Require (@($preview | Where-Object { $_ -is [Management.Automation.InformationRecord] }).Count -eq 6) 'Legacy dry run did not list six writes'
  Restore-NativeImeComponents -Components $legacyComponents | Out-Null
  Require ((Get-ItemProperty -LiteralPath $key).EngineHost -ceq 'legacy-host') 'Legacy host restore failed'
  Require ((Get-ItemProperty -LiteralPath $key).SettingsExe -ceq '') 'Rollback must preserve present empty string'
  $legacy.previous.PSObject.Properties.Remove('core')
  $legacyComponents = @(Get-NativeImeRollbackComponents -Record $legacy -RegistryKey $key -ClsidKey $ClsidKey -RunKey $UserRunKey -WarningAction SilentlyContinue)
  Require ($legacyComponents.Count -eq 5) 'Original legacy schema without core must touch only its five pointers'
  $legacyCore = [pscustomobject]@{ schema=2; core_only=$true; registry_key=$key; core='unused'; previous=[pscustomobject]@{core=$null} }
  $warnings = @()
  Restore-NativeImeCore -Record $legacyCore -DryRun -WarningVariable warnings -WarningAction SilentlyContinue
  Require ($warnings.Count -eq 1 -and [string]$warnings[0] -like "*$key\CoreDll*") 'Legacy core warning missing'
  Restore-NativeImeCore -Record $legacyCore -WarningAction SilentlyContinue
  Require ($null -eq (Get-ItemProperty -LiteralPath $key).PSObject.Properties['CoreDll']) 'Legacy core deletion failed'
  $output = @(Publish-NativeImeCore -Source $source -DestinationRoot (Join-Path $root 'dry-only') -RegistryKey $key -DryRun 6>&1) -join "`n"
  Require ($output.Contains('CoreDll from <absent> to [')) 'Core deploy dry run lacks exact values'
  Require (-not (Test-Path -LiteralPath (Join-Path $root 'dry-only'))) 'Core deploy dry run created files'
  foreach ($path in $deployPath, $rollbackPath, (Join-Path $PSScriptRoot '../scripts/core-deployment.ps1')) {
    [void][Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    Require ($errors.Count -eq 0) "Parse errors: $path"
  }
  Write-Output "PASS scoped rollback assertions=$assertions private_key=True wrapper_scripts_executed=False"
} finally {
  Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
}
