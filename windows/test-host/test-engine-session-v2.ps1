[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('session-v2-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO',
 'DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','NELISP_IME_ENGINE')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$hostProcess=$null;$pipe=$null;$checks=0
function Request([string]$request){
 $bytes=[Text.Encoding]::UTF8.GetBytes($request);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush()
 $buffer=New-Object byte[] 65536;$read=$pipe.ReadAsync($buffer,0,$buffer.Length)
 if(-not $read.Wait(30000)){throw "Timeout: $request"}
 if(-not $read.Result){throw 'Host closed pipe'}
 [Text.Encoding]::UTF8.GetString($buffer,0,$read.Result)
}
function Check([bool]$value,[string]$label){if(-not $value){throw "FAIL $label"};$script:checks++}
try{
 $env:LOCALAPPDATA=$run;$env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-EG2-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_PIPE_NAME='\\.\pipe\EG2-session-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo';$env:DDSKK_SKKSERV_ENABLE='0';$env:NELISP_IME_ENGINE='ddskk'
 $env:DDSKK_DICTIONARY_FILES=Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8'
 $hostProcess=Start-Process (Join-Path $build 'Release/ddskk-engine-host.exe') -ArgumentList @(('"'+$Runtime+'"'),('"'+$root+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'stdout.log') -RedirectStandardError (Join-Path $run 'host.log')
 Start-Sleep -Seconds $ColdLoadSleepSec
 $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut);$pipe.Connect(10000)
 Check ((Request 'SESSION a OPEN 2') -eq 'OK OPEN 2') 'open A'
 Check ((Request 'SESSION b OPEN 2') -eq 'OK OPEN 2') 'open B'
 [void](Request 'SESSION a V2 PREPARE 2 75,97,110,97');$a=Request 'SESSION a V2 SPACE 2'
 Check ($a -match '^STATE candidate ') 'prepared conversion'
 [void](Request 'SESSION b V2 PREPARE 2 75,97')
 Check ((Request 'SESSION a V2 STATUS') -eq $a) 'interleaved A unchanged'
 Check ((Request 'SESSION b V2 STATUS') -ne $a) 'B isolated'
 [void](Request 'SESSION a V2 CONTROL CONVERT')
 Check ((Request 'SESSION a V2 CONTROL PREVIOUS') -eq $a) 'next previous'
 for($i=0;$i -lt 65;$i++){[void](Request "SESSION eviction-$i OPEN 2")}
 Check ((Request 'DIAG SESSION-COUNT') -eq 'SESSIONS 64') 'bounded contexts'
 Check ((Request 'SESSION a V2 STATUS') -eq 'ERR SESSION LOST') 'LRU loss detected'
 [void](Request 'SESSION a OPEN 2');[void](Request 'SESSION a V2 PREPARE 2 75,97,110,97')
 Check ((Request 'SESSION a V2 SPACE 2') -eq $a) 'eviction fallback'
 $identity=[guid]::NewGuid().ToString('N')+'.1'
 $learn="LOCAL LEARN $identity 00304b00306a 004eee00540d"
 $ack=Request $learn;Check ($ack -match "^ACK $identity \d+$") 'durable learning ACK'
 # Stock DDSKK can narrow the candidate list after learning a user hit.
 # Capture the authoritative post-learning result before process replacement.
 [void](Request 'SESSION oracle OPEN 2');[void](Request 'SESSION oracle V2 PREPARE 2 75,97,110,97')
 $restartExpected=Request 'SESSION oracle V2 SPACE 2'
 [void](Request 'SESSION oracle CLOSE')
 $pidReply=Request 'DIAG CHILD-PID';Check ($pidReply -match '^PID (\d+)$') 'owned child identity'
 $child=Get-Process -Id ([int]$Matches[1])
 Check ([IO.Path]::GetFullPath($child.Path) -eq [IO.Path]::GetFullPath($Runtime) -and $child.StartTime.ToUniversalTime() -ge $hostProcess.StartTime.ToUniversalTime()) 'child belongs to private host'
 Stop-Process -Id $child.Id -Force
 Start-Sleep -Seconds $ColdLoadSleepSec
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$replacement=Request 'DIAG CHILD-PID';if($replacement -ne $pidReply){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $deadline)
 Check ($replacement -match '^PID \d+$' -and $replacement -ne $pidReply) 'actual engine restart'
 Check ((Request 'SESSION a V2 STATUS') -eq 'ERR SESSION LOST') 'restart invalidates session'
 [void](Request 'SESSION a OPEN 2');[void](Request 'SESSION a V2 PREPARE 2 75,97,110,97')
 Check ((Request 'SESSION a V2 SPACE 2') -eq $restartExpected) 'restart reading fallback'
 Check ((Request $learn) -eq $ack) 'operation ACK survives crash and retry'
 Check ((Request 'SESSION a CLOSE') -eq 'OK CLOSED') 'explicit close'
 [void](Request 'SHUTDOWN');$pipe.Dispose();$pipe=$null
 if(-not $hostProcess.WaitForExit(5000)){Stop-Process -Id $hostProcess.Id -Force}
 Write-Output "EG2 private sessions: $checks checks PASS (real restart, eviction, durable retry)"
}finally{
 if($pipe){$pipe.Dispose()}
 if($hostProcess -and -not $hostProcess.HasExited){Stop-Process -Id $hostProcess.Id -Force;[void]$hostProcess.WaitForExit(5000)}
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
