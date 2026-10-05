[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('crlf-host-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$saved=@{}
$names=@('LOCALAPPDATA','NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO',
         'DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_START_COMMAND',
         'DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT',
         'NELISP_IME_ENGINE')
foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$hostProcess=$null; $pipe=$null; $server=$null; $checks=0; $failures=0
function Check($value,[string]$label){
  $script:checks++
  if(-not $value){$script:failures++; Write-Output "FAIL $label"}
}
function Request([string]$text){
  $bytes=[Text.Encoding]::UTF8.GetBytes($text)
  $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
  $buffer=New-Object byte[] 65536
  $read=$pipe.ReadAsync($buffer,0,$buffer.Length)
  if(-not $read.Wait(30000)){throw "Private host timeout: $text"}
  [Text.Encoding]::UTF8.GetString($buffer,0,$read.Result)
}
try {
  $env:LOCALAPPDATA=$run
  $env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-test-crlf-'+[guid]::NewGuid().ToString('N')
  $env:DDSKK_PIPE_NAME='\\.\pipe\crlf-test-'+[guid]::NewGuid().ToString('N')
  $env:DDSKK_USER_JISYO=Join-Path $run 'user.jisyo'
  $env:DDSKK_SKKSERV_ENABLE='1'; $env:DDSKK_SKKSERV_START_COMMAND=''
  $probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $probe.Start(); $port=$probe.LocalEndpoint.Port; $probe.Stop()
  $ready=Join-Path $run 'server-ready'
  $server=Start-Job -ArgumentList $port,$ready -ScriptBlock {
    param($port,$ready)
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
    try {
      $listener.Start(); [IO.File]::WriteAllText($ready,'ready')
      while($true){
        $client=$listener.AcceptTcpClient()
        try {
          $stream=$client.GetStream(); $buffer=New-Object byte[] 4096
          while($stream.Read($buffer,0,$buffer.Length) -gt 0){
            $reply=[Text.Encoding]::UTF8.GetBytes("1/RelayA/`r/RelayB/`r`n")
            $stream.Write($reply,0,$reply.Length); $stream.Flush()
          }
        } finally {$client.Dispose()}
      }
    } finally {$listener.Stop()}
  }
  $deadline=[DateTime]::UtcNow.AddSeconds(15)
  while(-not (Test-Path -LiteralPath $ready)){
    if([DateTime]::UtcNow -gt $deadline){throw 'Private server startup timeout'}
    Start-Sleep -Milliseconds 100
  }
  $env:DDSKK_SKKSERV_HOST='127.0.0.1'; $env:DDSKK_SKKSERV_PORT=[string]$port
  $env:NELISP_IME_ENGINE='ddskk'
  $dict=Join-Path $run 'dictionary.utf8'
  $bom=Join-Path $run 'dictionary-bom.utf8'
  $utf8=[Text.UTF8Encoding]::new($false)
  # Made-up readings; control fields before and after real candidates.
  $reading=-join [char[]]@(0x304f,0x308b,0x3066,0x3059,0x3068)
  $bomReading=-join [char[]]@(0x307c,0x3080,0x3066,0x3059,0x3068)
  $broken=-join [char[]]@(0x304f,0x305a,0x308c)
  $okuri=([string][char]0x304f)+'z'
  $journal=-join [char[]]@(0x306b,0x3063,0x304d)
  [IO.File]::WriteAllText($dict,"$reading /Alpha/`r/Beta/`r`n",$utf8)
  [IO.File]::WriteAllText($bom,"$bomReading /Gamma/`r/Delta/`r`n",[Text.UTF8Encoding]::new($true))
  $env:DDSKK_DICTIONARY_FILES=$dict+';'+$bom
  [IO.File]::WriteAllText($env:DDSKK_USER_JISYO,"$broken /Alpha/Beta/`r/`r`n$okuri /`r/Gamma/`r`n",$utf8)
  [IO.File]::WriteAllText($env:DDSKK_USER_JISYO+'.journal',"$journal /`r/Delta/`r`n",$utf8)
  $hostProcess=Start-Process -FilePath (Join-Path $build 'Release/ddskk-engine-host.exe') `
    -ArgumentList @(('"'+$Runtime+'"'),('"'+$root+'"')) -WindowStyle Hidden -PassThru `
    -RedirectStandardError (Join-Path $run 'host.log') -RedirectStandardOutput (Join-Path $run 'stdout.log')
  Start-Sleep -Seconds $ColdLoadSleepSec
  $pipe=[IO.Pipes.NamedPipeClientStream]::new('.',$env:DDSKK_PIPE_NAME.Substring(9),[IO.Pipes.PipeDirection]::InOut)
  $pipe.Connect(10000)
  foreach($keys in @('Kurutesuto','Bomutesuto','Kuzure','KuZu','Nikki','Rire')){
    $encoded=([int[]][char[]]$keys)-join ','
    $reply=Request "SESSION crlf CONTROL CONVERT-KEYS $encoded"
    Write-Output "$keys $reply"
    Check ($reply -match '^STATE candidate ' -and $reply -notmatch '00000[ad]') "$keys no CR/LF candidates"
    [void](Request 'SESSION crlf CONTROL CANCEL')
  }
  foreach($path in @($env:DDSKK_USER_JISYO,($env:DDSKK_USER_JISYO+'.journal'))){
    Check (-not [IO.File]::ReadAllText($path).Contains("`r")) 'startup rewrite LF'
  }
  [void](Request 'SHUTDOWN'); $pipe.Dispose(); $pipe=$null
  if(-not $hostProcess.WaitForExit(5000)){Stop-Process -Id $hostProcess.Id -Force}
  Write-Output "Private CRLF host: $checks checks, $failures failures"
  if($failures){throw 'Private CRLF host regression'}
} finally {
  if($pipe){$pipe.Dispose()}
  # The host's kill-on-close job owns every engine child it started.
  if($hostProcess -and -not $hostProcess.HasExited){Stop-Process -Id $hostProcess.Id -Force; $hostProcess.WaitForExit()}
  if($server){Stop-Job $server; Remove-Job $server}
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
