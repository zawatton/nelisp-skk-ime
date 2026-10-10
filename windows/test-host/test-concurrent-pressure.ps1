[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [Parameter(Mandatory)][string]$LargeDictionary,
      [ValidateRange(45,45)][int]$ColdLoadSleepSec=45,
      [string]$SubstrateSource='', [switch]$ValidateParametersOnly, [switch]$DryRun)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=[IO.Path]::GetFullPath((Join-Path $root ($BuildDir+'/eh8-'+[guid]::NewGuid().ToString('N'))))
if(-not $run.StartsWith((Join-Path $root 'build')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){
  throw 'Concurrent pressure artifacts must be under this worktree build'
}
$pack=Join-Path $root 'windows/scripts/private-host-bundle.ps1'
$command=Get-Command $pack
foreach($parameter in 'Action','BundleDirectory','Runtime','HostPath','Mode','SubstrateSource'){
  if(-not $command.Parameters.ContainsKey($parameter)){throw "Missing private Pack parameter $parameter"}
}
if($ValidateParametersOnly){
  Write-Output 'PASS EH8 concurrent pressure parameter audit packs=2 cycles=1 clients=3 inline=1 stacks=0'
  return
}
[void](New-Item -ItemType Directory $run)
$old=Join-Path $run 'previous'
$new=Join-Path $run 'next'
if($DryRun){
  & python (Join-Path $PSScriptRoot 'prepare-concurrent-pressure.py') --previous $old --bundle $new --dry-run
  if($LASTEXITCODE -ne 0){throw 'Concurrent pressure dry run failed'}
  return
}
# Pack only copies immutable private artifacts; no deployment/live scripts run.
foreach($destination in $old,$new){
  $arguments=@('-NoProfile','-NonInteractive','-File',$pack,'-Action','Pack',
    '-BundleDirectory',$destination,'-Runtime',$Runtime,
    '-HostPath',(Join-Path $root "$BuildDir/Release/ddskk-engine-host.exe"),'-Mode','policy')
  if($SubstrateSource){$arguments+=@('-SubstrateSource',$SubstrateSource)}
  & pwsh @arguments
  if($LASTEXITCODE -ne 0){throw 'Private pressure bundle Pack failed'}
}
& python (Join-Path $PSScriptRoot 'prepare-concurrent-pressure.py') --previous $old --bundle $new
if($LASTEXITCODE -ne 0){throw 'Pressure instrumentation failed'}
$arguments=@((Join-Path $PSScriptRoot 'private-host-bundle-e2e.py'),
  '--previous',$old,'--bundle',$new,'--runtime',$Runtime,'--state',(Join-Path $run 'cycle'),
  '--dll',(Join-Path $root "$BuildDir/Release/ddskk-ime.dll"),
  '--core',(Join-Path $root "$BuildDir/Release/ddskk-ime-core.dll"),
  '--tsf-host',(Join-Path $root "$BuildDir/Release/tsf-host.exe"),
  '--large-dictionary',$LargeDictionary,'--clients','3','--inline',
  '--cold-load-sleep-sec',"$ColdLoadSleepSec",'--concurrent-pressure')
$log=Join-Path $run 'gate.log'
Write-Output ('cmd: python '+($arguments -join ' '))
& python (Join-Path $PSScriptRoot 'host-test-process-guard.py') run --root $root -- python @arguments *> $log
$code=$LASTEXITCODE
Get-Content $log -Tail 8
if($code -ne 0){throw "FAIL EH8 concurrent pressure exit=$code log=$log"}
$receipt=Get-Content (Join-Path $run 'cycle/concurrent-pressure.json') -Raw | ConvertFrom-Json
if($receipt.status -ne 'PASS' -or $receipt.owned_process_leaks -ne 0){throw 'Missing successful overlap/ownership receipt'}
Write-Output "PASS EH8 concurrent pressure cycles=1 clients=3 inline=1 phases=4 artifacts=$run"
