[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',[int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('learning-crash-v2-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$names=@('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO','DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','NELISP_IME_ENGINE','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LEARNING_HOLD_FILE')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$hostProcess=$null;$pipe=$null;$checks=0;$hold=Join-Path $run 'hold'
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
  Stop-Process -Id $hostProcess.Id -Force
  [void]$hostProcess.WaitForExit(5000)
 }
}
try{
 $env:LOCALAPPDATA=$run;$env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-test-EG2-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_PIPE_NAME='\\.\pipe\EG2-learning-crash-'+[guid]::NewGuid().ToString('N')
 $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo';$env:DDSKK_SKKSERV_ENABLE='0';$env:NELISP_IME_ENGINE='ddskk'
 $env:DDSKK_DICTIONARY_FILES=Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8'
 $env:DDSKK_HARNESS_DIAGNOSTICS='1';$env:NATIVEIME_TEST_LEARNING_HOLD_FILE=$hold
 StartPrivateHost 'before'
 $pidReply=Request 'DIAG CHILD-PID';Check ($pidReply -match '^PID (\d+)$') 'child identity'
 $child=Get-Process -Id ([int]$Matches[1])
 Check ([IO.Path]::GetFullPath($child.Path) -eq [IO.Path]::GetFullPath($Runtime) -and $child.StartTime.ToUniversalTime() -ge $hostProcess.StartTime.ToUniversalTime()) 'verified owned runtime'
 $operation=[guid]::NewGuid().ToString('N')+'.1'
 $learn="LOCAL LEARN $operation 00304b00306a 004eee00540d"
 [IO.File]::WriteAllText($hold,'hold')
 $bytes=[Text.Encoding]::UTF8.GetBytes($learn);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush()
 $buffer=New-Object byte[] 65536;$pending=$pipe.ReadAsync($buffer,0,$buffer.Length)
 $deadline=[DateTime]::UtcNow.AddSeconds(5)
 do{$text=(ReadLog);if($text.Contains('LEARNING_IO held')){break};Start-Sleep -Milliseconds 10}while([DateTime]::UtcNow -lt $deadline)
 Check ($text.Contains('LEARNING_IO held') -and -not $text.Contains('LEARNING_IO released_ms=')) 'worker held after durable staging before publication'
 Check (-not $pending.IsCompleted) 'durable operation remains unacknowledged'
 Check (Test-Path -LiteralPath ($env:DDSKK_USER_JISYO+'.eg2-checkpoint')) 'durable outbox exists'
 StopOwnedHost;Check ($hostProcess.HasExited) 'owned host terminated'
 Check ($child.WaitForExit(5000)) 'owned child job terminated'
 $pipe.Dispose();$pipe=$null;$hostProcess=$null
 if($pending.IsFaulted){$null=$pending.Exception}
 Remove-Item -LiteralPath $hold
 StartPrivateHost 'after'
 Check (-not (Test-Path -LiteralPath ($env:DDSKK_USER_JISYO+'.eg2-checkpoint'))) 'restart consumed staged checkpoint'
 Check ((Request 'LOCAL STATUS') -eq 'LOCAL 3 1') 'restart restores learning revision'
 Check ((Request $learn) -eq "ACK $operation 1") 'idempotent retry receives original durable ACK'
 Check ((Request $learn) -eq "ACK $operation 1") 'duplicate replay stays idempotent'
 Check ((Request 'LOCAL STATUS') -eq 'LOCAL 3 1') 'replay does not advance learning revision'
 $stored=[IO.File]::ReadAllText($env:DDSKK_USER_JISYO)
 Check ($stored.Contains(([char]0x304b).ToString()+[char]0x306a+' /'+[char]0x4eee+[char]0x540d+'/')) 'candidate order recovered'
 Check ($stored.Contains(';; local-ack '+$operation.Split('.')[0]+' 1 1')) 'operation identity recovered with candidate row'
 [void](Request 'SHUTDOWN');$pipe.Dispose();$pipe=$null
 Check ($hostProcess.WaitForExit(10000)) 'shutdown drains replay worker'
 Write-Output "EG2 learning crash: $checks checks PASS (host crash, staged outbox, idempotent replay)"
 Write-Output "Artifacts: $run"
}finally{
 if(Test-Path -LiteralPath $hold){Remove-Item -LiteralPath $hold}
 if($pipe){$pipe.Dispose()}
 StopOwnedHost
 foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
