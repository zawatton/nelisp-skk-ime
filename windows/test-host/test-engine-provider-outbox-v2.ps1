[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('provider-outbox-v2-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO','DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','NELISP_IME_ENGINE','DDSKK_HARNESS_DIAGNOSTICS','DDSKK_HOST_DEBUG')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$hostProcess=$null;$pipe=$null;$blocker=$null;$checks=0
function Check([bool]$value,[string]$label){if(-not $value){throw "FAIL $label"};$script:checks++}
function Request([string]$request){
 $bytes=[Text.Encoding]::UTF8.GetBytes($request);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush()
 $buffer=New-Object byte[] 65536;$read=$pipe.ReadAsync($buffer,0,$buffer.Length)
 if(-not $read.Wait(30000)){throw "Timeout: $request"};if(-not $read.Result){throw 'Host closed pipe'}
 [Text.Encoding]::UTF8.GetString($buffer,0,$read.Result)
}
function StartPrivateHost([string]$stage){
 $script:log=Join-Path $run ($stage+'-host.log')
 $script:hostProcess=Start-Process (Join-Path $build 'Release/ddskk-engine-host.exe') -ArgumentList @(('"'+$Runtime+'"'),('"'+$root+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run ($stage+'-stdout.log')) -RedirectStandardError $log
 Start-Sleep -Seconds $ColdLoadSleepSec
 $script:pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut);$pipe.Connect(10000)
}
function ReadLog {
 $file=[IO.FileStream]::new($log,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
 $reader=[IO.StreamReader]::new($file);try{$reader.ReadToEnd()}finally{$reader.Dispose();$file.Dispose()}
}
function StopOwnedHost {
 if($hostProcess -and -not $hostProcess.HasExited){
  if([IO.Path]::GetFullPath($hostProcess.Path) -ne (Join-Path $build 'Release/ddskk-engine-host.exe')){throw 'Owned host path mismatch'}
  Stop-Process -Id $hostProcess.Id -Force;[void]$hostProcess.WaitForExit(5000)
 }
}
try{
 $env:LOCALAPPDATA=$run;$env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-test-EG2-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_PIPE_NAME='\\.\pipe\EG2-provider-outbox-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo';$env:DDSKK_SKKSERV_ENABLE='0';$env:NELISP_IME_ENGINE='ddskk'
 $env:DDSKK_DICTIONARY_FILES=Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8'
 $env:DDSKK_HARNESS_DIAGNOSTICS='1';$env:DDSKK_HOST_DEBUG='1'
 StartPrivateHost 'before'
 $pidReply=Request 'DIAG CHILD-PID';Check ($pidReply -match '^PID (\d+)$') 'child identity'
 $child=Get-Process -Id ([int]$Matches[1])
 Check ([IO.Path]::GetFullPath($child.Path) -eq [IO.Path]::GetFullPath($Runtime) -and $child.StartTime.ToUniversalTime() -ge $hostProcess.StartTime.ToUniversalTime()) 'verified owned runtime'
 [void](Request 'SESSION warm OPEN 2');[void](Request 'SESSION warm V2 PREPARE 2 97,105');[void](Request 'SESSION warm V2 SPACE 2');Start-Sleep -Seconds 3;[void](Request 'SESSION warm V2 CONTROL COMMIT');[void](Request 'SESSION warm CLOSE')
 [void](Request 'SESSION a OPEN 2');[void](Request 'SESSION a V2 PREPARE 2 75,97,110,97')
 Check ((Request 'SESSION a V2 SPACE 2') -match '^STATE candidate ') 'provider conversion'
 # Deny creation/writes to the worker checkpoint, without any engine hook.
 $checkpoint=$env:DDSKK_USER_JISYO+'.eg2-checkpoint'
 $blocker=[IO.FileStream]::new($checkpoint,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $clock=[Diagnostics.Stopwatch]::StartNew()
 Check ((Request 'SESSION a V2 CONTROL COMMIT') -match '^STATE hiragana ') 'provider commit reply'
 Write-Output ('provider commit reply wall_ms={0:F6}' -f $clock.Elapsed.TotalMilliseconds)
 $deadline=[DateTime]::UtcNow.AddSeconds(2)
 do{$text=ReadLog;if($text.Contains('LEARNING_IO retry')){break};Start-Sleep -Milliseconds 10}while([DateTime]::UtcNow -lt $deadline)
 Check ($text.Contains('LEARNING_IO retry') -and $blocker.Length -eq 0) 'worker has not written checkpoint after reply'
 Check ((Test-Path ($env:DDSKK_USER_JISYO+'.eg2-outbox')) -and (Get-Item ($env:DDSKK_USER_JISYO+'.eg2-outbox')).Length -gt 0) 'durable producer outbox exists before crash'
 StopOwnedHost;Check ($hostProcess.HasExited) 'owned host terminated after reply'
 Check ($child.WaitForExit(5000)) 'owned runtime job terminated'
 $pipe.Dispose();$pipe=$null;$hostProcess=$null
 $blocker.Dispose();$blocker=$null;Remove-Item -LiteralPath $checkpoint
 StartPrivateHost 'after'
 $stored=if(Test-Path -LiteralPath $env:DDSKK_USER_JISYO){[IO.File]::ReadAllText($env:DDSKK_USER_JISYO)}else{''}
 $row=([char]0x304b).ToString()+[char]0x306a+' /'+[char]0x4eee+[char]0x540d+'/'
 Check ($stored.Contains($row)) 'provider learning survives before worker first write'
 Check (($stored.Split("`n") | Where-Object {$_.StartsWith($row)}).Count -eq 1) 'one learned row'
 $learnedRow=@($stored.Split("`n") | Where-Object {$_.StartsWith($row)})[0]
 Check (([regex]::Matches($learnedRow,[regex]::Escape(([char]0x4eee).ToString()+[char]0x540d))).Count -eq 1) 'one learned candidate'
 Check ((Request 'LOCAL STATUS') -eq 'LOCAL 3 1') 'learning revision exactly once'
 Check (-not (Test-Path ($env:DDSKK_USER_JISYO+'.eg2-outbox')) -or (Get-Item ($env:DDSKK_USER_JISYO+'.eg2-outbox')).Length -eq 0) 'durable operation retired'
 [void](Request 'SESSION after OPEN 2');[void](Request 'SESSION after V2 PREPARE 2 75,97,110,97')
 Check ((Request 'SESSION after V2 SPACE 2') -match '^STATE candidate .*004eee00540d') 'recovered learning available to conversion'
 [void](Request 'SHUTDOWN');$pipe.Dispose();$pipe=$null;Check ($hostProcess.WaitForExit(10000)) 'shutdown drained'
 StartPrivateHost 'again'
 Check ((Request 'LOCAL STATUS') -eq 'LOCAL 3 1') 'second restart does not learn twice'
 Check ([IO.File]::ReadAllText($env:DDSKK_USER_JISYO).Contains($row)) 'second restart preserves candidate'
 [void](Request 'SHUTDOWN');$pipe.Dispose();$pipe=$null;Check ($hostProcess.WaitForExit(10000)) 'second shutdown drained'
 Write-Output "EG2 provider outbox: $checks checks PASS (reply-before-write crash, exactly once, retirement)"
 Write-Output "Artifacts: $run"
}finally{
 if($pipe){$pipe.Dispose()};StopOwnedHost;if($blocker){$blocker.Dispose()}
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
