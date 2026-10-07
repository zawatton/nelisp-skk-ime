[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Runtime,
  [Parameter(Mandatory)][string]$Dictionary,
  [Parameter(Mandatory)][string]$Output,
  [string]$BuildDir = 'build/w',
  [string]$RepositoryPath = '',
  [string]$SkkServExecutable = '',
  [string]$SkkServDependencyDir = '',
  [string]$FixtureServerPython = '',
  [ValidateRange(31100,31199)][int]$Port = 31181,
  [ValidateRange(1,1000)][int]$Iterations = 20,
  [switch]$Profile,
  [switch]$Learning,
  [switch]$PersistentSessions,
  [ValidateRange(0,100)][int]$LearningBurstIterations = 0,
  [switch]$ServerOnly,
  [switch]$RequireQuiet,
  [ValidateRange(0,100)][int]$PersistentIterations = 0,
  [switch]$Contention,
  [ValidateRange(0,100)][int]$ProbeIterations = 0,
  [ValidateSet('plain','okuri')][string[]]$Kinds=@('plain','okuri'),
  [int]$ColdLoadSleepSec = 45
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$engineRoot=if ($RepositoryPath) { [IO.Path]::GetFullPath($RepositoryPath) } else { $root }
$build = [IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run = Join-Path $build ('conversion-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$copy = Join-Path $run 'SKK-JISYO.L.utf8'
Copy-Item -LiteralPath $Dictionary -Destination $copy
$corpus = Get-Content (Join-Path $PSScriptRoot 'conversion-corpus.json') -Raw | ConvertFrom-Json
$saved = @{}
$names = @('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO',
 'DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT',
 'DDSKK_SKKSERV_START_COMMAND','NELISP_IME_ENGINE','DDSKK_HOST_DEBUG','DDSKK_PHASE_TRACE','DDSKK_CONVERSION_PROFILE',
 'SKKSERV_INSTANCE','SKKSERV_CONFIG','SKKSERV_DICTIONARIES_CONFIG','SKKSERV_DICTIONARY',
 'SKKSERV_PORT','SKKSERV_AUTOSTART','SKKSERV_LOCAL_BACKEND','SKKSERV_GOOGLE_BACKEND',
 'SKKSERV_MECAB_BACKEND','SKKSERV_GOOGLE_CACHE','PATH')
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$hostProcess = $null; $serverProcess = $null; $pipe = $null
$rows = [Collections.Generic.List[object]]::new()
$learned = [Collections.Generic.List[object]]::new()
$coldLoads = [Collections.Generic.List[object]]::new()
$maintenance = [Collections.Generic.List[object]]::new()
$transactions = [Collections.Generic.List[object]]::new()
# Request framing matches host/main.cpp: one UTF-8 message, no newline.
function Request([string]$text, [string]$operation = '') {
  $clock=[Diagnostics.Stopwatch]::StartNew()
  $bytes = [Text.Encoding]::UTF8.GetBytes($text)
  $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
  $writeMs=$clock.Elapsed.TotalMilliseconds
  $buffer = New-Object byte[] 65536
  $read = $pipe.ReadAsync($buffer,0,$buffer.Length)
  if (-not $read.Wait(30000)) { throw "Host response timeout: $text" }
  $n = $read.Result
  $readMs=$clock.Elapsed.TotalMilliseconds-$writeMs
  if ($n -eq 0) { throw 'Host closed the pipe' }
  $reply=[Text.Encoding]::UTF8.GetString($buffer,0,$n)
  $transactions.Add([pscustomobject]@{request=$text;operation=$operation;writeMs=$writeMs;readMs=$readMs;
    decodeMs=$clock.Elapsed.TotalMilliseconds-$writeMs-$readMs;totalMs=$clock.Elapsed.TotalMilliseconds})
  $reply
}
function Load-Snapshot {
  # Two snapshots give interval CPU consumption, not lifetime CPU totals.
  $interval=[Diagnostics.Stopwatch]::StartNew()
  $before = @{}; Get-Process | ForEach-Object { try { $before[$_.Id] = $_.CPU } catch {} }
  Start-Sleep -Milliseconds 1000
  $top = @(Get-Process | ForEach-Object {
    if ($before.ContainsKey($_.Id)) { try {
      [pscustomobject]@{name=$_.ProcessName; pid=$_.Id; cpuMs=[Math]::Round(1000*($_.CPU-$before[$_.Id]),1)}
    } catch {} }
  } | Sort-Object cpuMs -Descending | Select-Object -First 8)
  [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o'); intervalMs=$interval.Elapsed.TotalMilliseconds; processors=[Environment]::ProcessorCount; top=$top}
}
try {
  $env:LOCALAPPDATA=$run; $env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-L1-'+[guid]::NewGuid().ToString('N')
  $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo'
  $env:DDSKK_DICTIONARY_FILES=$copy; $env:DDSKK_SKKSERV_HOST='127.0.0.1'
  $env:DDSKK_SKKSERV_PORT="$Port"; $env:DDSKK_SKKSERV_START_COMMAND=''
  $env:NELISP_IME_ENGINE='ddskk'; $env:DDSKK_HOST_DEBUG='1'; $env:DDSKK_PHASE_TRACE='1'
  $env:DDSKK_CONVERSION_PROFILE=if ($Profile) {'1'} else {'0'}
  if ($SkkServExecutable -or $FixtureServerPython) {
    if ($SkkServExecutable -and -not $SkkServDependencyDir) {
      $SkkServDependencyDir=Split-Path (Get-Command emacs.exe -ErrorAction Stop).Source
    }
    if ($SkkServDependencyDir) {$env:PATH=$SkkServDependencyDir+';'+$env:PATH}
    # Reserve/check only the selected test port before starting our server.
    # If another instance owns it, fail without querying that instance.
    $portProbe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$Port)
    try { $portProbe.Start() } finally { $portProbe.Stop() }
    $env:SKKSERV_INSTANCE='L1-'+[guid]::NewGuid().ToString('N')
    $env:SKKSERV_CONFIG=Join-Path $run 'server.conf'
    $env:SKKSERV_DICTIONARIES_CONFIG=Join-Path $run 'dictionaries.conf'
    $env:SKKSERV_DICTIONARY=$copy; $env:SKKSERV_PORT="$Port"
    $env:SKKSERV_AUTOSTART='1'; $env:SKKSERV_LOCAL_BACKEND='1'
    $env:SKKSERV_GOOGLE_BACKEND='0'; $env:SKKSERV_MECAB_BACKEND='0'
    $env:SKKSERV_GOOGLE_CACHE=Join-Path $run 'cache'
    [IO.File]::WriteAllLines($env:SKKSERV_CONFIG,@($copy,"$Port",'1','1','0','0','86400'))
    [IO.File]::WriteAllText($env:SKKSERV_DICTIONARIES_CONFIG,"1`t$copy`n")
    if ($FixtureServerPython) {
      $serverProcess=Start-Process -FilePath $FixtureServerPython -WorkingDirectory $run -WindowStyle Hidden -PassThru `
        -ArgumentList @('-u',('"'+(Join-Path $PSScriptRoot 'profile-eg1-server.py')+'"'),'--dictionary',('"'+$copy+'"'),'--port',"$Port") `
        -RedirectStandardOutput (Join-Path $run 'server-stdout.log') -RedirectStandardError (Join-Path $run 'server-stderr.log')
    } else {
      $serverProcess=Start-Process -FilePath $SkkServExecutable -WorkingDirectory $run -WindowStyle Hidden -PassThru `
      -RedirectStandardOutput (Join-Path $run 'server-stdout.log') -RedirectStandardError (Join-Path $run 'server-stderr.log')
    }
    $serverHandle=$serverProcess.Handle
    # Large dictionaries can take much longer than a fixture to index.
    # Check an actual L hit; a listening TCP socket alone is insufficient.
    $serverReady=$false; $serverWatch=[Diagnostics.Stopwatch]::StartNew()
    for ($attempt=0; $attempt -lt 60; $attempt++) {
      if ($serverProcess.HasExited) { throw "Private server exited: $($serverProcess.ExitCode)" }
      $probe=$null
      try {
        $probe=[Net.Sockets.TcpClient]::new('127.0.0.1',$Port)
        $stream=$probe.GetStream(); $stream.ReadTimeout=2000
        $bytes=[Text.Encoding]::UTF8.GetBytes('1'+[string][char]0x304b+[string][char]0x306a+' ')
        $stream.Write($bytes,0,$bytes.Length)
        $first=$stream.ReadByte()
        if ($first -eq 49) { $serverReady=$true; break }
      } catch {} finally {if($probe){$probe.Dispose()}}
      Start-Sleep -Seconds 1
    }
    [IO.File]::WriteAllText((Join-Path $run 'server-readiness.txt'),
      "ready=$serverReady attempts=$($attempt+1) wallMs=$($serverWatch.Elapsed.TotalMilliseconds) pid=$($serverProcess.Id)")
    if (-not $serverReady) { throw "Private server failed full-L lookup readiness: $run" }
  }
  $env:DDSKK_SKKSERV_ENABLE=if ($SkkServExecutable -or $FixtureServerPython) {'1'} else {'0'}
  $load=Load-Snapshot
  if ($RequireQuiet) {
    $attempts=[Collections.Generic.List[object]]::new()
    for ($attempt=0; $attempt -lt 10; $attempt++) {
      $attempts.Add($load)
      $busy=@($load.top | Where-Object { $_.pid -ne $PID -and $_.cpuMs / $load.intervalMs -gt .3 })
      if (-not $busy.Count) { break }
      Write-Output "Quiet check: heavy processes present; retry $($attempt+1)/10"
      Start-Sleep -Seconds 5
      $load=Load-Snapshot
    }
    $attempts | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $run 'quiet-attempts.json')
    if ($busy.Count) { throw 'Machine remains busy; wall-clock gates not measured' }
  }
  if ($ServerOnly) {
    if (-not ($SkkServExecutable -or $FixtureServerPython)) { throw 'ServerOnly requires a private server' }
    $empty=Join-Path $run 'empty-host-jisyo.utf8'
    [IO.File]::WriteAllText($empty,';; Private empty host tier: benchmark the server relay.')
    $env:DDSKK_DICTIONARY_FILES=$empty
  }
  # Restart for each kind so both first-conversion measurements are cold.
  foreach ($kind in $Kinds) {
    $env:DDSKK_PIPE_NAME='\\.\pipe\ddskk-L1-'+[guid]::NewGuid().ToString('N')
    $hostProcess=Start-Process -FilePath (Join-Path $build 'Release/ddskk-engine-host.exe') `
      -ArgumentList @(('"'+$Runtime+'"'),('"'+$engineRoot+'"')) -WindowStyle Hidden -PassThru `
      -RedirectStandardError (Join-Path $run "$kind-host.log") -RedirectStandardOutput (Join-Path $run "$kind-stdout.log")
    Start-Sleep -Seconds $ColdLoadSleepSec
    $pipe=[IO.Pipes.NamedPipeClientStream]::new('.', $env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut)
    $pipe.Connect(10000)
    $pidReply=Request 'DIAG CHILD-PID'
    if ($pidReply -notmatch '^PID (\d+)$') { throw "Invalid PID response: $pidReply" }
    $engine=Get-Process -Id ([int]$Matches[1])
    if ($PersistentSessions) { [void](Request "SESSION bench OPEN 2") }
    $items=@($corpus | Where-Object kind -eq $kind)
    for ($attempt=0; $attempt -lt 10; $attempt++) {
      $coldLoad=Load-Snapshot
      $coldLoads.Add([pscustomobject]@{kind=$kind; stage='before'; load=$coldLoad})
      $coldBusy=@($coldLoad.top | Where-Object { $_.pid -ne $PID -and $_.cpuMs/$coldLoad.intervalMs -gt .3 })
      if (-not $RequireQuiet -or -not $coldBusy.Count) {break}
      Write-Output "Cold $kind quiet check: heavy processes present; retry $($attempt+1)/10"
      Start-Sleep -Seconds 5
    }
    $coldLoads | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $run 'cold-load.json')
    if ($RequireQuiet -and $coldBusy.Count) {throw "Cold $kind machine remains busy; wall gate not measured"}
    for ($i=0; $i -le $Iterations; $i++) {
      foreach ($item in $(if ($i -eq 0) { @($items[0]) } else { $items })) {
        $encoded=([int[]][char[]]$item.keys) -join ','
        $engine.Refresh(); $cpu=$engine.TotalProcessorTime.TotalMilliseconds
        $timer=[Diagnostics.Stopwatch]::StartNew()
        if ($PersistentSessions) {
          [void](Request 'SESSION bench RESET')
          [void](Request "SESSION bench V2 PREPARE 2 $encoded" 'prepare-reading')
          $timer.Restart(); $engine.Refresh(); $cpu=$engine.TotalProcessorTime.TotalMilliseconds
        }
        $reply=if ($PersistentSessions) {
          Request "SESSION bench V2 SPACE 2" 'prepared-space'
        } else { Request "SESSION bench CONTROL CONVERT-KEYS $encoded" }
        $timer.Stop(); $engine.Refresh()
        if ($reply -notmatch '^STATE candidate ') { throw "Conversion failed $($item.name): $reply" }
        $rows.Add([pscustomobject]@{kind=$kind; name=$item.name; cold=($i -eq 0); iteration=$i;
          wallMs=$timer.Elapsed.TotalMilliseconds; cpuMs=($engine.TotalProcessorTime.TotalMilliseconds-$cpu); response=$reply})
        if ($i -eq 0) {
          $coldLoad=Load-Snapshot
          $coldLoads.Add([pscustomobject]@{kind=$kind; stage='after'; load=$coldLoad})
          $coldLoads | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $run 'cold-load.json')
          if ($RequireQuiet -and @($coldLoad.top | Where-Object { $_.pid -ne $PID -and $_.cpuMs/$coldLoad.intervalMs -gt .3 }).Count) {
            throw "Machine became busy during cold $kind measurement; retry with a fresh host"
          }
        }
        [void](Request 'SESSION bench CONTROL CANCEL')
      }
    }
    $engine.Refresh(); $gcCpu=$engine.TotalProcessorTime.TotalMilliseconds
    $gcTimer=[Diagnostics.Stopwatch]::StartNew(); $gcReply=Request 'GC'; $gcTimer.Stop(); $engine.Refresh()
    $maintenance.Add([pscustomobject]@{kind=$kind; response=$gcReply; wallMs=$gcTimer.Elapsed.TotalMilliseconds;
      cpuMs=($engine.TotalProcessorTime.TotalMilliseconds-$gcCpu)})
    # Compare a warm, already-fed session's Space barrier to raw-key replay.
    # Key requests still serialize responses; their cost is in transactions.
    for ($iteration=0; $iteration -lt $PersistentIterations; $iteration++) {
      foreach ($item in $items) {
        [void](Request 'SESSION bench RESET')
        $prefix=''
        foreach ($key in [char[]]$item.keys) {
          $prefix+=$key
          if ($PersistentSessions) {
            $encodedPrefix=([int[]][char[]]$prefix) -join ','
            [void](Request "SESSION bench V2 PREPARE 2 $encodedPrefix" 'prepare-suffix')
          } else { [void](Request ('SESSION bench KEY '+[int]$key)) }
        }
        $operation=if($iteration -eq 0){'persistent-space-new'}else{'persistent-space-learned'}
        $encoded=([int[]][char[]]$item.keys) -join ','
        $reply=if ($PersistentSessions) { Request "SESSION bench V2 SPACE 2" $operation }
               else { Request 'SESSION bench CONTROL CONVERT' $operation }
        if ($reply -notmatch '^STATE candidate ') {throw "Persistent conversion failed: $reply"}
        [void](Request 'SESSION bench CONTROL CONVERT' 'persistent-next')
        [void](Request 'SESSION bench CONTROL PREVIOUS' 'persistent-previous')
        [void](Request 'SESSION bench CONTROL COMMIT' 'persistent-commit')
        [void](Request 'HELLO 1')
      }
    }
    for ($probe=0; $probe -lt $ProbeIterations; $probe++) {
      [void](Request 'WIRE UTF8 1' 'metadata-hop')
      [void](Request 'SESSION bench HELLO 1' 'same-session-noop')
    }
    if ($Contention) {
      # A second private client makes the real shared-engine mutex visible.
      $other=[IO.Pipes.NamedPipeClientStream]::new('.', $env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut)
      try {
        $other.Connect(10000)
        if ($PersistentSessions) {
          [void](Request 'SESSION second OPEN 2')
          [void](Request 'SESSION second V2 PREPARE 2 75,97,110,97')
          [void](Request 'SESSION learning OPEN 2')
          [void](Request 'SESSION learning V2 CONVERT-LIVE 2 75,97,110,97')
          $commit=[Text.Encoding]::UTF8.GetBytes('SESSION learning V2 CONTROL COMMIT')
          $other.Write($commit,0,$commit.Length); $other.Flush()
          [void](Request 'SESSION second V2 CONVERT-LIVE 2 75,97,110,97' 'commit-then-second-conversion')
          $buffer=New-Object byte[] 65536
          $pending=$other.ReadAsync($buffer,0,$buffer.Length)
          if (-not $pending.Wait(30000)) {throw 'Learning contention response timeout'}
          $commitReply=[Text.Encoding]::UTF8.GetString($buffer,0,$pending.Result)
          if ($commitReply -notmatch '^STATE ') {throw "Learning commit failed: $commitReply"}
          [void](Request 'SESSION second CONTROL CANCEL')
        }
        $bytes=[Text.Encoding]::UTF8.GetBytes('GC')
        $other.Write($bytes,0,$bytes.Length); $other.Flush()
        Start-Sleep -Milliseconds 20
        [void](Request 'HELLO 1' 'queued-behind-gc')
        $buffer=New-Object byte[] 65536
        $pending=$other.ReadAsync($buffer,0,$buffer.Length)
        if (-not $pending.Wait(30000)) {throw 'Contending GC response timeout'}
        if ($pending.Result -eq 0) {throw 'Contending client disconnected'}
      } finally {$other.Dispose()}
    }
    if ($Learning) {
      foreach ($item in $items) {
        $encoded=([int[]][char[]]$item.keys) -join ','
        $first=Request "SESSION bench CONTROL CONVERT-KEYS $encoded"
        $selected=Request 'SESSION bench CONTROL CONVERT' 'candidate-next'
        if ($selected -notmatch '^STATE candidate ') { throw "No second candidate for $($item.name)" }
        [void](Request 'SESSION bench CONTROL COMMIT' 'learning-commit')
        $again=Request "SESSION bench CONTROL CONVERT-KEYS $encoded"
        $learned.Add([pscustomobject]@{name=$item.name; first=$first; selected=$selected; learned=$again})
        [void](Request 'SESSION bench CONTROL CANCEL')
      }
    }
    if ($LearningBurstIterations) {
      [void](Request 'SESSION burst OPEN 2')
      for ($burst=0; $burst -lt $LearningBurstIterations; $burst++) {
        [void](Request 'SESSION burst V2 PREPARE 2 75,97,110,97' 'burst-prepare')
        $converted=Request 'SESSION burst V2 SPACE 2' 'burst-space'
        if ($converted -notmatch '^STATE candidate ') {throw "Burst conversion failed: $converted"}
        $committed=Request 'SESSION burst V2 CONTROL COMMIT' 'burst-commit'
        if ($committed -notmatch '^STATE ') {throw "Burst commit state failed: $committed"}
      }
    }
    [void](Request 'SHUTDOWN'); $pipe.Dispose(); $pipe=$null
    if (-not $hostProcess.WaitForExit(5000)) { Stop-Process -Id $hostProcess.Id -Force }
    $hostProcess=$null
  }
  $result=[pscustomobject]@{schema=1; persistentSessions=[bool]$PersistentSessions; runtimeHash=(Get-FileHash $Runtime).Hash;
    dictionaryHash=(Get-FileHash $copy).Hash; corpusHash=(Get-FileHash (Join-Path $PSScriptRoot 'conversion-corpus.json')).Hash;
    server=[bool]($SkkServExecutable -or $FixtureServerPython); fixtureServer=[bool]$FixtureServerPython; serverOnly=[bool]$ServerOnly; quietRequired=[bool]$RequireQuiet;
    load=$load; loadAfter=(Load-Snapshot);
    coldLoads=$coldLoads.ToArray(); maintenance=$maintenance.ToArray(); traceDir=$run; samples=$rows.ToArray(); learning=$learned.ToArray(); transactions=$transactions.ToArray()}
  $result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $Output
  foreach ($kind in $Kinds) {
    $warm=@($rows | Where-Object { $_.kind -eq $kind -and -not $_.cold })
    foreach ($metric in @('cpuMs','wallMs')) {
      $values=@($warm | ForEach-Object { $_.$metric } | Sort-Object)
      Write-Output ("{0} {1} n={2} p50={3:F3} p90={4:F3} max={5:F3}" -f $kind,$metric,$values.Count,
        $values[[int][Math]::Ceiling($values.Count*.5)-1],$values[[int][Math]::Ceiling($values.Count*.9)-1],$values[-1])
    }
    $rows | Where-Object { $_.kind -eq $kind -and $_.cold } | Select-Object kind,cpuMs,wallMs
  }
} finally {
  if ($pipe) { $pipe.Dispose() }
  # The host owns a kill-on-close job for its engine children.
  foreach ($process in @($hostProcess,$serverProcess)) {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force; [void]$process.WaitForExit(5000) }
  }
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
}
