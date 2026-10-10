[CmdletBinding()]
param(
  [ValidateSet('Pack','Deploy','Rollback','Recover','Cycle')][string]$Action = 'Pack',
  [Parameter(Mandatory)][string]$BundleDirectory,
  [Parameter(Mandatory)][string]$Runtime,
  [string]$HostPath,
  [string]$Repository = (Join-Path $PSScriptRoot '../..'),
  [string]$SubstrateSource,
  [ValidateSet('native','policy')][string]$Mode = 'policy',
  [string]$StateDirectory,
  [string]$PreviousBundleDirectory,
  [string]$RegistryKey,
  [string]$PipeName,
  [int]$ColdLoadSleepSec = 45,
  [int]$LifetimeSec = 60,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$BundleDirectory = [IO.Path]::GetFullPath($BundleDirectory)
if (-not $BundleDirectory.StartsWith(($root + '\build\'), [StringComparison]::OrdinalIgnoreCase)) {
  throw 'BundleDirectory must be under this checkout build directory'
}
$Runtime = (Resolve-Path -LiteralPath $Runtime).Path
if ($Action -eq 'Pack') {
  if (-not $HostPath) { throw 'Pack requires -HostPath' }
  $HostPath = (Resolve-Path -LiteralPath $HostPath).Path
  $Repository = (Resolve-Path -LiteralPath $Repository).Path
  if (-not $SubstrateSource) { $SubstrateSource = Join-Path $Repository '../nelisp/src' }
  $SubstrateSource = (Resolve-Path -LiteralPath $SubstrateSource).Path
  if (Test-Path -LiteralPath $BundleDirectory) { throw 'Bundle must be a new immutable directory' }
  if ($DryRun) {
    Write-Output "DRYRUN Pack host=$HostPath repository=$Repository mode=$Mode destination=$BundleDirectory"
    return
  }
  [void](New-Item -ItemType Directory -Path $BundleDirectory)
  Copy-Item -LiteralPath $HostPath -Destination (Join-Path $BundleDirectory 'ddskk-engine-host.exe')
  [void](New-Item -ItemType Directory -Path (Join-Path $BundleDirectory 'repository'))
  foreach ($directory in 'engine','framework','engines','vendor') {
    Copy-Item -LiteralPath (Join-Path $Repository $directory) -Destination (Join-Path $BundleDirectory 'repository') -Recurse
  }
  [void](New-Item -ItemType Directory -Path (Join-Path $BundleDirectory 'nelisp'))
  Copy-Item -LiteralPath $SubstrateSource -Destination (Join-Path $BundleDirectory 'nelisp') -Recurse
  $manifest = @('schema=1','contract=engine-host-v1','policy_ipc=HP2',"mode=$Mode",
    ('host_sha256=' + (Get-FileHash -LiteralPath (Join-Path $BundleDirectory 'ddskk-engine-host.exe')).Hash.ToLowerInvariant()),
    ('runtime_sha256=' + (Get-FileHash -LiteralPath $Runtime).Hash.ToLowerInvariant()),
    ('policy_sha256=' + (Get-FileHash -LiteralPath (Join-Path $BundleDirectory 'repository/engine/host-policy.el')).Hash.ToLowerInvariant()))
  [IO.File]::WriteAllLines((Join-Path $BundleDirectory 'bundle.manifest'), $manifest, [Text.UTF8Encoding]::new($false))
  Write-Output "PACK bundle=$BundleDirectory mode=$Mode files=host,repository,manifest"
  return
}
# No defaults can select the live registry, pipe or data directory. This script
# never changes registry pointers or registrations; a coordinator supplies the
# private TSF fixture settings. Foreground ownership lasts through the test.
if ($RegistryKey.Length -ge 200 -or $RegistryKey -notmatch '^Software\\NativeIME-test-[A-Za-z0-9-]+$') { throw 'Explicit bounded private RegistryKey required' }
if ($PipeName.Length -ge 190 -or $PipeName -notmatch '^EH5-[A-Za-z0-9-]+$') { throw 'Explicit bounded EH5- private PipeName required' }
if (-not $StateDirectory) { throw 'Explicit private StateDirectory required' }
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
if (-not $StateDirectory.StartsWith(($root + '\build\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'StateDirectory must be under this checkout build directory' }
if ($DryRun) {
  Write-Output "DRYRUN $Action bundle=$BundleDirectory previous=$PreviousBundleDirectory state=$StateDirectory key=$RegistryKey pipe=$PipeName; no writes/processes"
  return
}
$arguments = @((Join-Path $root 'windows/test-host/private-host-bundle.py'),
  '--action',$Action.ToLowerInvariant(),'--bundle',$BundleDirectory,'--runtime',$Runtime,
  '--state',$StateDirectory,'--key',$RegistryKey,'--pipe',$PipeName,
  '--cold-load-sleep-sec',"$ColdLoadSleepSec",'--lifetime-sec',"$LifetimeSec")
if ($PreviousBundleDirectory) {
  $PreviousBundleDirectory = [IO.Path]::GetFullPath($PreviousBundleDirectory)
  if (-not $PreviousBundleDirectory.StartsWith(($root + '\build\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Previous bundle must be under this checkout build directory' }
  $arguments += @('--previous',$PreviousBundleDirectory)
}
& python (Join-Path $root 'windows/test-host/host-test-process-guard.py') run --root $root -- python @arguments
if ($LASTEXITCODE -ne 0) { throw "Private bundle $Action failed: exit=$LASTEXITCODE" }
