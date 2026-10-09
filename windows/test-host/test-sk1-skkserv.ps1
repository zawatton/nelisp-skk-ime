[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45,
      [string[]]$Cases=@('extra','server-only','slow','unreachable','toggle'),
      [string]$EquivalenceFixture='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('sk1-tsf-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$corpus=$null
if($EquivalenceFixture) {
 $path=[IO.Path]::GetFullPath((Join-Path $root $EquivalenceFixture))
 $expected=([IO.File]::ReadAllText([IO.Path]::ChangeExtension($path,'.sha256')) -split '\s+')[0]
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'SK1 equivalence fixture checksum changed'}
 $corpus=[IO.File]::ReadAllText($path) | ConvertFrom-Json
 if($corpus.version -ne 1 -or $Cases -notcontains 'extra'){throw 'SK1 extra equivalence fixture requires extra case'}
}
$file=Join-Path $run 'files.utf8'
[IO.File]::WriteAllText($file,";; okuri-ari entries.`n;; okuri-nasi entries.`nかな /仮名/哉/`nあい /愛/`n",$utf8)
$names=@('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT')
$saved=@{}; foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$checks=0
try {
 $env:DDSKK_DICTIONARY_FILES=$file; $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 foreach($name in @('DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT')){[Environment]::SetEnvironmentVariable($name,$null)}
 foreach($case in $Cases) {
  $fixture=$null; $port=31102
  try {
   if($case -ne 'unreachable') {
    $delay=if($case -eq 'slow'){400}else{0}
    $fixture=Start-Process python -WindowStyle Hidden -PassThru -ArgumentList @('-u',('"'+(Join-Path $PSScriptRoot 'sk1-skkserv-fixture.py')+'"'),'--port',$port,'--delay-ms',$delay) -RedirectStandardOutput (Join-Path $run ($case+'-fixture.log')) -RedirectStandardError (Join-Path $run ($case+'-fixture.err'))
    Start-Sleep -Milliseconds 400
    if($fixture.HasExited){throw 'Fixture failed to start'}
   }
   $script='a i SPACE WAIT3000 ENTER K a n a SPACE WAIT400 SETTLE8000:FIRST SPACE SETTLE8000:SECOND SPACE SETTLE8000:THIRD ENTER SETTLE8000:END'
   switch($case) {
    'server-only' {$script='a i SPACE WAIT3000 ENTER N a z o SPACE SETTLE8000:ONLY ENTER SETTLE8000:END'}
    'extra' {$script+=' K a n a SPACE SETTLE8000:LEARNED ENTER SETTLE8000:LEARNEDEND'}
    'slow' {$script='a i SPACE WAIT3000 ENTER K a n a SPACE ENTER SETTLE8000:END'}
    'unreachable' {$script='a i SPACE WAIT3000 ENTER K a n a SPACE ENTER SETTLE8000:END'}
    'toggle' {$script='a i SPACE WAIT3000 ENTER K a n a SPACE WAIT400 SKKSERV0 WAIT200 MIRROR SKKSERV1 WAIT400 MIRROR SPACE SPACE SETTLE8000:THIRD ENTER SETTLE8000:END'}
   }
   $log=Join-Path $run ($case+'.log')
   & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') -Script $script `
    -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime -RepositoryPath $root `
    -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
    -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -SkkServEnable 1 -SkkServPort $port `
    -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory (Join-Path $run $case) *> $log
   if($LASTEXITCODE -ne 0){throw "Harness failed: $log"}
   $text=[IO.File]::ReadAllText($log)
   function Expect([string]$label,[string]$value) {
    if($text -notmatch ('AFTER '+$label+' BUF=\['+[regex]::Escape($value)+'\]')){throw "Mismatch $case/$label`: $log"}; $script:checks++
   }
   if($case -eq 'server-only'){Expect ONLY 'あい▼serverOnly'; Expect END 'あいserverOnly'}
   elseif($case -in @('slow','unreachable')){Expect END 'あい仮名'}
   else {Expect THIRD 'あい▼serverExtra'; Expect END 'あいserverExtra'}
   if($case -eq 'extra'){Expect FIRST 'あい▼仮名'; Expect SECOND 'あい▼哉'; Expect LEARNED 'あいserverExtra▼serverExtra'}
   if($case -eq 'extra' -and $corpus) {
    foreach($checkpoint in $corpus.checkpoints.PSObject.Properties){Expect $checkpoint.Name $checkpoint.Value}
    Write-Output "PASS SK1 extra corpus checkpoints=$($corpus.checkpoints.PSObject.Properties.Name.Count)"
   }
   if($case -eq 'toggle') {
    if($text -notmatch 'SKKSERV toggle status=0' -or $text -notmatch 'MIRROR stable=1 line=STATE candidate .* 0 004eee00540d,0054c9' -or $text -notmatch '000073000065000072000076000065000072000045000078000074000072000061'){throw "Config toggle vectors failed: $log"}; $checks++
   }
   if($case -ne 'server-only') {
    $times=@([regex]::Matches($text,'SPACE-CANDIDATE ms=\d+ .*path=local us=(\d+)')|ForEach-Object{[long]$_.Groups[1].Value})
    if(-not $times.Count -or @($times|Where-Object{$_ -gt 5000}).Count){throw "Local SPACE exceeded 5ms: $log"}; $checks++
   }
   if($text -match 'SETTLE TIMEOUT|UnknownToken'){throw "Invalid or stalled case: $log"}
   Write-Output "PASS SK1 TSF case=$case checks=$checks log=$log"
  } finally {if($fixture){if(-not $fixture.HasExited){Stop-Process -Id $fixture.Id -Force}; $fixture.WaitForExit(); $fixture.Dispose()}}
 }
 Write-Output "PASS SK1 TSF cases=$($Cases.Count) checks=$checks artifacts=$run"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
