[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('learning-v2-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO','DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','NELISP_IME_ENGINE','DDSKK_HARNESS_DIAGNOSTICS','DDSKK_HOST_DEBUG','NATIVEIME_TEST_LEARNING_HOLD_FILE','NATIVEIME_TEST_LOCAL_CONVERSION')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$hostProcess=$null;$a=$null;$b=$null;$c=$null;$checks=0;$transactions=@()
$hold=Join-Path $run 'hold';$log=Join-Path $run 'host.log'
function Request($stream,[string]$request){
 $clock=[Diagnostics.Stopwatch]::StartNew()
 $bytes=[Text.Encoding]::UTF8.GetBytes($request);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
 $buffer=New-Object byte[] 65536;$read=$stream.ReadAsync($buffer,0,$buffer.Length)
 if(-not $read.Wait(30000)){throw "Timeout: $request"}
 if(-not $read.Result){throw 'Host closed pipe'}
 $script:transactions+=@{request=$request;wallMs=$clock.Elapsed.TotalMilliseconds}
 [Text.Encoding]::UTF8.GetString($buffer,0,$read.Result)
}
function ReadLog {
 $file=[IO.FileStream]::new($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $reader=[IO.StreamReader]::new($file)
 try{$reader.ReadToEnd()}finally{$reader.Dispose();$file.Dispose()}
}
function Check([bool]$value,[string]$label){if(-not $value){throw "FAIL $label"};$script:checks++}
try{
 $env:LOCALAPPDATA=$run;$env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-test-EG2-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_PIPE_NAME='\\.\pipe\EG2-learning-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo';$env:DDSKK_SKKSERV_ENABLE='0';$env:NELISP_IME_ENGINE='ddskk'
 $env:DDSKK_DICTIONARY_FILES=Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8'
 $env:DDSKK_HARNESS_DIAGNOSTICS='1';$env:DDSKK_HOST_DEBUG='1';$env:NATIVEIME_TEST_LOCAL_CONVERSION='1';$env:NATIVEIME_TEST_LEARNING_HOLD_FILE=$hold
 $hostProcess=Start-Process (Join-Path $build 'Release/ddskk-engine-host.exe') -ArgumentList @(('"'+$Runtime+'"'),('"'+$root+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'stdout.log') -RedirectStandardError $log
 Start-Sleep -Seconds $ColdLoadSleepSec
 $a=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut);$a.Connect(10000)
 $b=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut);$b.Connect(10000)
 [void](Request $a 'SESSION warm OPEN 2');[void](Request $a 'SESSION warm V2 PREPARE 2 97,105');[void](Request $a 'SESSION warm V2 SPACE 2');Start-Sleep -Seconds 3;[void](Request $a 'SESSION warm V2 CONTROL COMMIT')
 [void](Request $a 'SESSION warm CLOSE')
 [void](Request $b 'SESSION b OPEN 2');[void](Request $b 'SESSION b V2 PREPARE 2 75,97,110,97')
 [void](Request $a 'SESSION a OPEN 2');[void](Request $a 'SESSION a V2 PREPARE 2 75,97,110,97');Check ((Request $a 'SESSION a V2 SPACE 2') -match '^STATE candidate ') 'A conversion'
 [IO.File]::WriteAllText($hold,'hold')
 Check ((Request $a 'SESSION a V2 CONTROL COMMIT') -match '^STATE hiragana ') 'commit returns final state'
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{$text=(ReadLog);if($text.Contains('LEARNING_IO held')){break};Start-Sleep -Milliseconds 10}while([DateTime]::UtcNow -lt $deadline)
 Check ($text.Contains('LEARNING_IO held') -and -not $text.Contains('LEARNING_IO released_ms=')) 'commit returns with learning I/O blocked'
 Check ((Request $b 'SESSION b V2 SPACE 2') -match '^STATE candidate ') 'second client immediate prepared Space'
 $text=(ReadLog)
 Check (-not $text.Contains('LEARNING_IO released_ms=')) 'second client finishes before learning I/O release'
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{$text=(ReadLog);if($text -match 'LOCAL publication status=LOCAL 3 1 capabilities=3'){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Check ($text -match 'LOCAL publication status=LOCAL 3 1 capabilities=3') 'overlay published while learning I/O blocked'
 Check (-not $text.Contains('request=LOCAL SNAPSHOT')) 'native overlay avoids interpreter snapshot'
 $c=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut);$c.Connect(10000)
 $client=[guid]::NewGuid().ToString('N');$id=$client+'.1'
 $bytes=[Text.Encoding]::UTF8.GetBytes("LOCAL LEARN $id 00304b00306a 004eee00540d")
 $c.Write($bytes,0,$bytes.Length);$c.Flush();$ackBuffer=New-Object byte[] 65536;$ackRead=$c.ReadAsync($ackBuffer,0,$ackBuffer.Length)
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{$text=(ReadLog);if($text -match 'LOCAL publication status=LOCAL 3 2 capabilities=3'){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Check (-not $ackRead.IsCompleted) 'LOCAL durable ACK stays pending during worker I/O'
 Check ($text -match 'LOCAL publication status=LOCAL 3 2 capabilities=3') 'overlay publishes while durable LOCAL ACK is pending'
 Check (-not $text.Contains('LEARNING_IO released_ms=')) 'overlay revision two precedes I/O release'

 $match=[regex]::Match($text,'request-lock[^\r\n]*qpc_wait_ms=([0-9.]+) request=SESSION b V2 SPACE 2')
 Check ($match.Success) 'second Space QPC wait recorded'
 Write-Output ('second-client SPACE QPC mutex_wait_ms='+$match.Groups[1].Value)
 Remove-Item -LiteralPath $hold
 Check ($ackRead.Wait(30000)) 'durable ACK completes after storage release'
 Check ([Text.Encoding]::UTF8.GetString($ackBuffer,0,$ackRead.Result) -match "^ACK $id 2$") 'durable identity and revision confirmed'
 $c.Dispose();$c=$null
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{$text=(ReadLog);if([regex]::Matches($text,'LOCAL publication status=LOCAL 3 2 capabilities=3').Count -ge 2){break};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 Check ([regex]::Matches($text,'LOCAL publication status=LOCAL 3 2 capabilities=3').Count -ge 2) 'durable watermark republishes without a new learning revision'
 [void](Request $a 'SHUTDOWN');$a.Dispose();$a=$null;$b.Dispose();$b=$null
 Check ($hostProcess.WaitForExit(10000)) 'shutdown flushes learning worker'
 $stored=[IO.File]::ReadAllText($env:DDSKK_USER_JISYO)
 Check ($stored.Contains('かな /仮名/')) 'committed learning durable after drain'
 $transactions | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $run 'transactions.json')
 Write-Output "EG2 learning: $checks checks PASS (reply, second client, overlay, shutdown)"
 Write-Output "Artifacts: $run"
}finally{
 if(Test-Path -LiteralPath $hold){Remove-Item -LiteralPath $hold}
 if($a){$a.Dispose()};if($b){$b.Dispose()};if($c){$c.Dispose()}
 if($hostProcess -and -not $hostProcess.HasExited){Stop-Process -Id $hostProcess.Id -Force;[void]$hostProcess.WaitForExit(5000)}
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
