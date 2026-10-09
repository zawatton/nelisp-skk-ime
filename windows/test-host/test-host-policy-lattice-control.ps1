[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$run=Join-Path $root ($BuildDir+'/lattice-policy-control-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('DDSKK_HOST_POLICY_SOURCES','DDSKK_HOST_POLICY_CACHE','DDSKK_HOST_POLICY_RESTART',
  'DDSKK_HOST_POLICY_PUBLICATION','DDSKK_HOST_POLICY_LEARNING','DDSKK_HOST_POLICY_SHADOW',
  'DDSKK_HOST_POLICY_TEST_PAUSE_KIND','NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$results=@()
try {
  foreach($value in @('0','1')) {
    foreach($name in $names[0..4]){[Environment]::SetEnvironmentVariable($name,$value)}
    $env:DDSKK_HOST_POLICY_SHADOW='0'
    foreach($name in $names[6..7]){[Environment]::SetEnvironmentVariable($name,$null)}
    $log=Join-Path $run "policy-$value.log"
    Write-Output "cmd: test-lattice-behavior.ps1 policy=$value cold=$ColdLoadSleepSec log=$log"
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'test-lattice-behavior.ps1') `
      -RepositoryPath $root -DllPath (Join-Path $bin 'ddskk-ime.dll') `
      -TsfHostExe (Join-Path $bin 'tsf-host.exe') -EngineHostPath (Join-Path $bin 'ddskk-engine-host.exe') `
      -EngineExecutablePath $Runtime -ColdLoadSleepSec $ColdLoadSleepSec *> $log
    $code=$LASTEXITCODE;Get-Content -LiteralPath $log -Tail 15
    $text=Get-Content -LiteralPath $log -Raw
    $results+=@{exit=$code;warm_failure=$text -match 'Lattice behavior failed: warm first candidate within 150 ms';
      blocked=$text -match 'Access to the registry key .* is denied'}
    # The harness owns and reaps its host/children in finally before returning.
    # Do not start the next stack if a host from this build is still alive.
    $remaining=@(Get-Process ddskk-engine-host,tsf-host -ErrorAction SilentlyContinue |
      Where-Object {$_.Path -and [IO.Path]::GetDirectoryName($_.Path) -eq $bin})
    if($remaining.Count){throw "Owned build host remains after policy=$value"}
    Write-Output "CLEANUP policy=$value worktree_hosts=0"
  }
  $classification=if($results[0].blocked -or $results[1].blocked){'HKCU-blocked'}
    elseif($results[0].warm_failure){'native-reproduces-warm-failure'}
    elseif($results[0].exit -eq 0 -and $results[1].warm_failure){'policy-only-warm-failure'}
    elseif($results[0].exit -eq 0 -and $results[1].exit -eq 0){'both-pass'}else{'unclassified-failure'}
  Write-Output "LATTICE_CONTROL native_exit=$($results[0].exit) authority_exit=$($results[1].exit) classification=$classification artifacts=$run"
  if($results[0].exit -ne 0 -or $results[1].exit -ne 0){throw 'Lattice control contains a failed or blocked gate; no acceptance claimed'}
} finally {
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
