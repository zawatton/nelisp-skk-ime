[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45,
      [string[]]$Cases=@('ordinary','offline','missing','corrupt','disabled','app-disabled','app-enabled','uncertified','okuri'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-tsf-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$saved=@{}; foreach ($name in @('DDSKK_HARNESS_DIAGNOSTICS','DDSKK_HOST_DEBUG','DDSKK_SEARCH_KATAKANA')) {
  $saved[$name]=[Environment]::GetEnvironmentVariable($name)
}
$checks=0
try {
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'; $env:DDSKK_HOST_DEBUG='1'
 foreach ($case in $Cases) {
  $script='a i SPACE WAIT3000 ENTER K a n a SPACE SETTLE30000:FIRST ENTER SETTLE30000:COMMIT'
  $arguments=@{LocalConversion=1; LocalIndexFailure='none'; ApplicationLocalConversion=-1}
  $switchArguments=@()
  $local=$true
  switch ($case) {
   ordinary { $script='a i SPACE WAIT3000 ENTER K a n a SPACE SETTLE30000:FIRST SPACE SETTLE30000:NEXT x SETTLE30000:PREVIOUS CTRLG SETTLE30000:RESTORE SPACE ENTER SETTLE30000:COMMIT K a n a SPACE SPACE K a n a SPACE ENTER SETTLE30000:AHEAD WAIT3000' }
   offline { $switchArguments=@('-StopEngineAfterWarmup'); $script='a i SPACE WAIT3000 ENTER K a n a SPACE SPACE ENTER K a n a SPACE ENTER SETTLE30000:AHEAD' }
   missing { $arguments.LocalIndexFailure='missing'; $local=$false }
   corrupt { $arguments.LocalIndexFailure='corrupt'; $local=$false }
   disabled { $arguments.LocalConversion=0; $local=$false }
   app-disabled { $arguments.ApplicationLocalConversion=0; $local=$false }
   app-enabled { $arguments.LocalConversion=0; $arguments.ApplicationLocalConversion=1 }
   uncertified { $env:DDSKK_SEARCH_KATAKANA='1'; $local=$false }
   okuri { $script='a i SPACE WAIT3000 ENTER K i e R u ENTER SETTLE30000:COMMIT'; $local=$false }
   default { throw "Unknown case $case" }
  }
  $log=Join-Path $run ($case+'.log')
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script $script -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') `
    -EngineExecutablePath $Runtime -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') `
    -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') `
    -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run $case) @arguments @switchArguments *> $log
  if ($LASTEXITCODE -ne 0) { Get-Content $log -Tail 20; throw "Harness failed: $case" }
  $text=[IO.File]::ReadAllText($log)
  function Expect([string]$label,[string]$hex) {
    $line=@($text -split "`n" | Where-Object { $_ -match ('^AFTER '+$label+' BUF=\[(.*)\] SEL=') })[-1]
    if ($line -notmatch '^AFTER \S+ BUF=\[(.*)\] SEL=') { throw "Missing $case/$label" }
    $actual=($Matches[1].ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ }) -join ''
    if ($actual -ne $hex) { throw "Mismatch $case/$label expected=$hex actual=$actual log=$log" }
    $script:checks++
  }
  if ($local -and $text -notmatch 'branch=local-convert') { throw "No local conversion: $case" }
  if (-not $local -and $text -match 'branch=local-convert') { throw "Unexpected local capability: $case" }
  $checks++
  switch ($case) {
   ordinary {
    Expect FIRST '3042304425bc4eee540d'; Expect NEXT '3042304425bc54c9'
    Expect PREVIOUS '3042304425bc4eee540d'; Expect RESTORE '3042304425bd304b306a'
    Expect COMMIT '304230444eee540d'; Expect AHEAD '304230444eee540d54c954c9'
    if ($text -match 'branch=provider-(queue|accept-and-queue)' -or $text -notmatch 'LOCAL_ACK ') { throw "Typing replay/learning failure: $log" }
    $checks++
   }
   offline {
    Expect AHEAD '3042304454c954c9'
    if ($text -notmatch 'LOCAL_LEARNING queued=1 pending=2' -or $text -match 'PROVIDER done') { throw "Offline/pending failure: $log" }
    $checks++
   }
   okuri { Expect COMMIT '304230446d883048308b' }
   default { Expect FIRST '3042304425bc4eee540d'; Expect COMMIT '304230444eee540d' }
  }
  $env:DDSKK_SEARCH_KATAKANA=$saved.DDSKK_SEARCH_KATAKANA
  Write-Output "PASS local TSF case=$case log=$log"
 }
 Write-Output "PASS local TSF cases=$($Cases.Count) checks=$checks artifacts=$run"
} finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
