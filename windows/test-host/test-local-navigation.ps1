[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('lf4-nav-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$source=Join-Path $run 'shared.utf8';$personal=Join-Path $run 'personal.utf8'
$utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($source,"かな /仮名/佳奈/加奈/可奈/哉/金/香奈/花菜/奏/叶/華奈/河南/`nかんじ /漢字/幹事/感じ/`nていこうち /抵抗値/`nかk /書/掛/`nは /葉/歯/`n",$utf8)
[IO.File]::WriteAllText($personal,"ていこうち /抵抗値/`nおーむ /Ω/`nていこうち /抵抗値/`n",$utf8)
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LOCAL_WORKER_STALL_MS')) {$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try {
 $env:DDSKK_DICTIONARY_FILES=$personal+';'+$source;$env:DDSKK_HARNESS_DIAGNOSTICS='1';$env:NATIVEIME_TEST_LOCAL_WORKER_STALL_MS='5000'
 $script='CTX2 a i SPACE WAIT3000 ENTER CTX1 K a n a REFUSEWRITE SPACE WAIT200 SETTLE8000:FIRST MIRROR SPACE SETTLE8000:NEXT x SETTLE8000:PREV SPACE SSPACE SETTLE8000:SHIFT_PREV SPACE CTRLP SETTLE8000:CTRL_PREV PGDN SETTLE8000:PAGE1 MIRROR PGDN SETTLE8000:PAGE2 MIRROR x SETTLE8000:MENU_X SPACE SETTLE8000:MENU_NEXT CTRLP SETTLE8000:MENU_CTRL SPACE SSPACE SETTLE8000:MENU_SHIFT PGDN PGUP SETTLE8000:BACKPAGE UP SETTLE8000:UP DOWN SETTLE8000:DOWN HOME x SETTLE8000:READING SPACE ENTER K a n a SPACE SPACE SPACE SPACE SPACE s SETTLE8000:MENU_COMMIT K a n j i REFUSEWRITE SPACE WAIT200 SETTLE8000:LEARNING_FIRST MIRROR MIRRORLOCK RIGHT LEFT WAIT300 MIRRORUNLOCK WAIT100 SETTLE8000:UNLOCKED MIRROR ENTER WAIT6500 T e i k o u c h i REFUSEWRITE SPACE WAIT200 SETTLE8000:PUBLISHED_FIRST MIRROR ENTER T e i k o u t i SPACE ENTER K a K u SPACE SSPACE SETTLE8000:OKURI_PREV x SETTLE8000:OKURI_READING CTRLG K a K u ENTER SETTLE8000:END MIRROR APPCLEAR H a REFUSEWRITES6000 SPACE WAIT5500 SETTLE8000:EXPIRED WAIT1000 SPACE SETTLE8000:RETRY_BOUND ENTER SETTLE8000:BOUND_END MIRROR'
 $log=Join-Path $run 'navigation.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') -Script $script -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime -RepositoryPath $root -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory $run *> $log
 if($LASTEXITCODE -ne 0){throw "Harness failed $log"}
 $text=[IO.File]::ReadAllText($log)
 $checkpoints=@{FIRST='▼仮名';NEXT='▼佳奈';PREV='▼仮名';SHIFT_PREV='▼仮名';CTRL_PREV='▼仮名';PAGE1='▼哉';PAGE2='▼河南';BACKPAGE='▼哉';UP='▼可奈';DOWN='▼哉';READING='▽かな';MENU_X='▼哉';MENU_NEXT='▼河南';MENU_CTRL='▼哉';MENU_SHIFT='▼哉';MENU_COMMIT='仮名金';LEARNING_FIRST='仮名金▼漢字';UNLOCKED='仮名金▼漢字';PUBLISHED_FIRST='仮名金漢字▼抵抗値';OKURI_PREV='仮名金漢字抵抗値抵抗値▼書く';OKURI_READING='仮名金漢字抵抗値抵抗値▽かく';END='仮名金漢字抵抗値抵抗値書く';EXPIRED='▽は';RETRY_BOUND='▼葉';BOUND_END='葉'}
 foreach($label in $checkpoints.Keys){if($text -notmatch ('AFTER '+$label+' BUF=\['+[regex]::Escape($checkpoints[$label])+'\]')){throw "Checkpoint $label failed: $log"}}
 $mirror=@([regex]::Matches($text,'MIRROR stable=1 line=(STATE [^\r\n]+)') | ForEach-Object {$_.Groups[1].Value})
 if($mirror.Count -ne 8 -or $mirror[0] -notmatch '^STATE candidate ' -or $mirror[1] -notmatch ' 0 0054c9,' -or $mirror[2] -notmatch ' 0 006cb3005357$' -or $mirror[3] -notmatch '^STATE candidate ' -or $mirror[4] -notmatch '^STATE candidate ' -or $mirror[5] -notmatch '0062b5006297005024$' -or $mirror[6] -notmatch '^STATE hiragana ' -or $mirror[7] -notmatch '^STATE hiragana '){throw "Stale/missing Sumi page: $log"}
 if($text -notmatch 'LOCAL_EDIT abandoned=1 pending=0' -or $text -notmatch 'MIRROR locked=1' -or $text -notmatch 'MIRROR unlocked=1' -or $text -notmatch 'LOCAL_EDIT recovered=1' -or $text -notmatch 'LOCAL_WORKER stalled_ms=5000' -or $text -match 'SETTLE TIMEOUT|branch=provider-(queue|accept-and-queue|convert)'){throw "Local transition stranded: $log"}
 $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
 $edits=@([regex]::Matches($text,'LOCAL_RETRY total_us=(\d+)') | ForEach-Object {[int]$_.Groups[1].Value})
 $times+=$edits
 $max=($times | Measure-Object -Maximum).Maximum
 if(-not $times.Count -or $max -gt 25000){throw "Callback watchdog exceeded 25000 us: $max"}
 Write-Output "PASS local navigation checkpoints=$($checkpoints.Count) mirrors=$($mirror.Count) callbacks=$($times.Count) max_us=$max log=$log"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
