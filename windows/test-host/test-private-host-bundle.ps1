[CmdletBinding()]
param(
  [ValidateSet('Artifacts','Compatibility','Lifecycle','Recovery','EndToEnd')][string]$Stage = 'Artifacts',
  [Parameter(Mandatory)][string]$Runtime,
  [string]$BuildDir = 'build/w',
  [int]$ColdLoadSleepSec = 45,
  [string[]]$RecoveryPoints = @('before-handover','after-release','during-prewarm','after-prewarm','after-commit')
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run = Join-Path $root ($BuildDir + '/eh5-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $run)
$hostPath = Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"
$deploy = Join-Path $root 'windows/scripts/private-host-bundle.ps1'
$old = Join-Path $run 'native'
$new = Join-Path $run 'policy'
$gates = 0
function Gate([string]$name,[string]$exe,[string[]]$arguments) {
  $log = Join-Path $run "$name.log"
  Write-Output ("cmd: $exe " + ($arguments -join ' '))
  & python (Join-Path $PSScriptRoot 'host-test-process-guard.py') run --root $root -- $exe @arguments *> $log
  $code=$LASTEXITCODE
  Get-Content -LiteralPath $log -Tail 8
  if ($code -ne 0) { throw "FAIL $name exit=$code log=$log" }
  $script:gates++
}
foreach ($mode in 'native','policy') {
  $bundle = if ($mode -eq 'native') {$old} else {$new}
  Gate "pack-$mode" 'pwsh' @('-NoProfile','-File',$deploy,'-Action','Pack',
    '-BundleDirectory',$bundle,'-Runtime',$Runtime,'-HostPath',$hostPath,'-Mode',$mode)
}
Gate 'artifact-controls' 'python' @((Join-Path $PSScriptRoot 'private-host-bundle-controls.py'),
  '--bundle',$new,'--runtime',$Runtime,'--state',(Join-Path $run 'controls'), '--deploy',$deploy)
if ($Stage -eq 'Compatibility') {
  Gate 'startup-fallback' 'python' @((Join-Path $PSScriptRoot 'private-host-bundle-controls.py'),
    '--bundle',$new,'--runtime',$Runtime,'--state',(Join-Path $run 'startup'), '--deploy',$deploy,
    '--startup','--cold-load-sleep-sec',"$ColdLoadSleepSec")
}
if ($Stage -in 'Lifecycle','EndToEnd') {
  Gate 'old-new-old' 'pwsh' @('-NoProfile','-File',$deploy,'-Action','Cycle',
    '-BundleDirectory',$new,'-PreviousBundleDirectory',$old,'-Runtime',$Runtime,
    '-StateDirectory',(Join-Path $run 'cycle'),'-RegistryKey',('Software\NativeIME-test-' + [guid]::NewGuid().ToString('N')),
    '-PipeName',('EH5-' + [guid]::NewGuid().ToString('N')),'-ColdLoadSleepSec',"$ColdLoadSleepSec")
}
if ($Stage -eq 'Recovery') {
  Gate 'bundle-recovery' 'python' (@((Join-Path $PSScriptRoot 'private-host-bundle-recovery.py'),
    '--bundle',$new,'--previous',$old,'--runtime',$Runtime,'--state',(Join-Path $run 'recovery'),
    '--cold-load-sleep-sec',"$ColdLoadSleepSec",'--points') + $RecoveryPoints)
  Gate 'blocked-storage' 'python' @((Join-Path $PSScriptRoot 'private-host-bundle.py'),'--action','storage',
    '--bundle',$new,'--runtime',$Runtime,'--state',(Join-Path $run 'storage'),
    '--key',('Software\NativeIME-test-' + [guid]::NewGuid().ToString('N')),
    '--pipe',('EH5-' + [guid]::NewGuid().ToString('N')),'--cold-load-sleep-sec',"$ColdLoadSleepSec")
}
if ($Stage -eq 'EndToEnd') {
  foreach ($inline in @($false,$true)) {
    $arguments = @((Join-Path $PSScriptRoot 'private-host-bundle-e2e.py'),
      '--bundle',$new,'--previous',$old,'--runtime',$Runtime,'--state',(Join-Path $run "same-client-$inline"),
      '--dll',(Join-Path $root "$BuildDir/Release/ddskk-ime.dll"),'--core',(Join-Path $root "$BuildDir/Release/ddskk-ime-core.dll"),
      '--tsf-host',(Join-Path $root "$BuildDir/Release/tsf-host.exe"),'--cold-load-sleep-sec',"$ColdLoadSleepSec")
    if ($inline) {$arguments += '--inline'}
    Gate "same-client-$inline" 'python' $arguments
  }
  # Existing real core/scoped rollback gates are deliberately unchanged. All
  # require private HKCU and are coordinator-run when worker access is denied.
  Gate 'core-deployment' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-core-deployment.ps1'),
    '-CoreDllPath',(Join-Path $root "$BuildDir/Release/ddskk-ime-core.dll"),'-ArtifactDirectory',(Join-Path $run 'core-deploy'))
  Gate 'scoped-rollback' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-scoped-rollback.ps1'),
    '-ArtifactDirectory',(Join-Path $run 'scoped'))
  Gate 'core-hot-swap' 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-core-hot-swap.ps1'),
    '-EngineExecutablePath',$Runtime,'-BuildDirectory',(Join-Path $root "$BuildDir/Release"),
    '-ArtifactDirectory',(Join-Path $run 'core-swap'),'-ColdLoadSleepSec',"$ColdLoadSleepSec")
  foreach ($bundle in $old,$new,$old) {
    $env:DDSKK_HOST_BUNDLE_MANIFEST = Join-Path $bundle 'bundle.manifest'
    foreach ($switch in 'SOURCES','CACHE','RESTART','PUBLICATION','LEARNING') {
      [Environment]::SetEnvironmentVariable("DDSKK_HOST_POLICY_$switch", $(if ($bundle -eq $new) {'1'} else {'0'}))
    }
    $label = "input-$gates"
    Gate $label 'pwsh' @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-emacs-integration.ps1'),
      '-DllPath',(Join-Path $root "$BuildDir/Release/ddskk-ime.dll"),'-TsfHostExe',(Join-Path $root "$BuildDir/Release/tsf-host.exe"),
      '-EngineHostPath',(Join-Path $bundle 'ddskk-engine-host.exe'),'-RepositoryPath',(Join-Path $bundle 'repository'),
      '-EngineExecutablePath',$Runtime,'-ColdLoadSleepSec',"$ColdLoadSleepSec")
    $env:HOME=[Environment]::GetFolderPath('UserProfile')
    Gate "$label-inline" 'python' @((Join-Path $PSScriptRoot 'test-inline-preedit.py'),
      '--case','emacs','--dll',(Join-Path $root "$BuildDir/Release/ddskk-ime.dll"),
      '--tsf-host',(Join-Path $root "$BuildDir/Release/tsf-host.exe"),'--engine-host',(Join-Path $bundle 'ddskk-engine-host.exe'),
      '--core',(Join-Path $root "$BuildDir/Release/ddskk-ime-core.dll"),
      '--runtime',$Runtime,'--repository',$root,'--engine-repository',(Join-Path $bundle 'repository'),'--artifacts',(Join-Path $run $label),
      '--cold-load',"$ColdLoadSleepSec")
  }
}
Write-Output "PASS S5 $Stage gates=$gates artifacts=$run"
