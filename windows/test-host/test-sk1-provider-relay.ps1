[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w',
      [string]$DictionaryFiles='', [int]$ColdLoadSleepSec=45, [switch]$Tsf)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('sk1-provider-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
if(-not $DictionaryFiles) {
 $DictionaryFiles=Join-Path $run 'files.utf8'
 [IO.File]::WriteAllText($DictionaryFiles,";; okuri-ari entries.`nかk /書/掛/[く/書/]/`n;; okuri-nasi entries.`nか /蚊/`nかな /仮名/佳奈/`n",[Text.UTF8Encoding]::new($false))
}
$names=@('NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO','LOCALAPPDATA','APPDATA',
 'DDSKK_DICTIONARY_FILES','DDSKK_SKKSERV_ENABLE','DDSKK_SKKSERV_HOST','DDSKK_SKKSERV_PORT',
 'DDSKK_SKKSERV_START_COMMAND','DDSKK_HOST_DEBUG','NELISP_IME_ENGINE',
 'DDSKK_HARNESS_DLL_PATH','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_HARNESS_TSF_OUTPUT')
$saved=@{}; foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$checks=0
try {
 foreach($mode in @('disabled','unreachable')) {
  $data=Join-Path $run $mode; New-Item -ItemType Directory $data | Out-Null
  # No registry writes are needed for this provider-only gate. This private,
  # nonexistent key prevents any fallback to the live NativeIME configuration.
  $env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-test-sk1-provider-'+[guid]::NewGuid().ToString('N')
  $pipe='ddskk-test-sk1-provider-'+[guid]::NewGuid().ToString('N')
  $env:DDSKK_PIPE_NAME='\\.\pipe\'+$pipe
  $env:DDSKK_USER_JISYO=Join-Path $data 'user.utf8'; $env:LOCALAPPDATA=$data; $env:APPDATA=$data
  $env:DDSKK_DICTIONARY_FILES=$DictionaryFiles; $env:DDSKK_HOST_DEBUG='1'
  $env:DDSKK_SKKSERV_ENABLE=if($mode -eq 'disabled'){'0'}else{'1'}
  $env:DDSKK_SKKSERV_HOST='127.0.0.1'; $env:DDSKK_SKKSERV_PORT='31199'
  $env:DDSKK_SKKSERV_START_COMMAND=$null; $env:NELISP_IME_ENGINE='ddskk'
  $owned=$null; $client=$null; $childPid=0; $tsfProcess=$null
  function Request([string]$line) {
   $bytes=[Text.Encoding]::UTF8.GetBytes($line+"`n"); $client.Write($bytes,0,$bytes.Length)
   $buffer=[byte[]]::new(65536); $pending=$client.ReadAsync($buffer,0,$buffer.Length)
   if(-not $pending.Wait(30000)){throw "Provider response timeout: $line"}
   $reply=[Text.Encoding]::UTF8.GetString($buffer,0,$pending.Result).Trim()
   "REQUEST=$line RESPONSE=$reply" | Add-Content -LiteralPath (Join-Path $data 'responses.log')
   return $reply
  }
  function Require([bool]$value,[string]$label) {
   if(-not $value){throw "Provider $mode/$label failed: $data"}; $script:checks++
  }
  try {
   $owned=Start-Process (Join-Path $build 'Release/ddskk-engine-host.exe') -WindowStyle Hidden -PassThru `
    -ArgumentList @(('"'+$Runtime+'"'),('"'+$root+'"')) `
    -RedirectStandardOutput (Join-Path $data 'host.stdout.log') -RedirectStandardError (Join-Path $data 'host.stderr.log')
   $client=[IO.Pipes.NamedPipeClientStream]::new('.', $pipe,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous)
   $client.Connect(30000); Start-Sleep -Seconds $ColdLoadSleepSec
   $pidReply=Request 'DIAG CHILD-PID'; Require ($pidReply -match '^PID ([1-9]\d*)$') 'child pid'
   $childPid=[int]$Matches[1]
   Require ((Request 'CONTROL CONVERT-KEYS 75,97') -match '^STATE candidate ') 'warm-up'
   Require ((Request 'RESET') -match '^STATE hiragana ') 'warm-up reset'
   $sid=[guid]::NewGuid().ToString('N')
   Require ((Request "SESSION $sid CONTROL SYNC-KEYS 75,97,75") -match '^STATE preedit .* 00006b -1 -$') 'okuri marker'
   Require ((Request "SESSION $sid KEY 117") -match '^STATE candidate .* 0 0066f8,00639b(?:,|$)') 'okuri vowel and file order'
   Require ((Request "SESSION $sid CONTROL COMMIT") -match '^STATE hiragana .*0066f800304f') 'okuri commit'
   Require ((Request "SESSION $sid CONTROL CONVERT-KEYS 75,97,110,97") -match '^STATE candidate .* 0 004eee00540d,') 'file conversion'
   Require ((Request "SESSION $sid RESET") -match '^STATE hiragana ') 'file reset'
   # Exercise a complete kana reading absent from the fixture and stock L.
   Require ((Request "SESSION $sid CONTROL CONVERT-KEYS 78,97,122,111,110,97,122,111,110,97,122,111,110,97,122,111") -match '^STATE registration ') 'absent reading'
   Require ((Request "SESSION $sid RESET") -match '^STATE hiragana ') 'miss reset'
   if($Tsf) {
    # Default InitialKanaMode=1 and LocalConversion=0 exercise the provider
    # path without registry writes. Do not treat this as a settings/swap gate.
    $env:DDSKK_HARNESS_DLL_PATH=Join-Path $build 'Release/ddskk-ime.dll'
    $env:DDSKK_HARNESS_DIAGNOSTICS='1'
    $env:NATIVEIME_HARNESS_TSF_OUTPUT=Join-Path $data 'tsf.stdout.log'
    $tsfProcess=Start-Process (Join-Path $build 'Release/tsf-host.exe') -WindowStyle Hidden -PassThru `
     -ArgumentList @('K a K u SETTLE8000 SPACE SETTLE8000 ENTER SETTLE5000') `
     -RedirectStandardOutput $env:NATIVEIME_HARNESS_TSF_OUTPUT -RedirectStandardError (Join-Path $data 'tsf.stderr.log')
    if(-not $tsfProcess.WaitForExit(60000)){throw 'Private TSF provider timeout'}
    Require ($tsfProcess.ExitCode -eq 0) 'TSF exit'
    $text=[IO.File]::ReadAllText($env:NATIVEIME_HARNESS_TSF_OUTPUT)
    Require ($text -match 'KEYLAT token=u .*claimed=1') 'TSF okuri vowel claimed'
    Require ($text -match 'AFTER SETTLE8000 BUF=\[▼書く\]') 'TSF okuri conversion'
    Require ($text -match 'AFTER SETTLE5000 BUF=\[掛く\] SEL=2,2 COMP=-' -and $text -notmatch 'SETTLE TIMEOUT') 'TSF navigation and commit'
   }
   Write-Output "PASS SK1 provider mode=$mode checks=$checks artifacts=$data"
  } finally {
   if($tsfProcess) {
    if(-not $tsfProcess.HasExited){Stop-Process -Id $tsfProcess.Id -Force; $tsfProcess.WaitForExit()}
    Write-Output "OWNED_TSF_EXITED=$($tsfProcess.HasExited)"; $tsfProcess.Dispose()
   }
   if($owned) {
    try {if($client -and $client.IsConnected){Request 'SHUTDOWN' | Out-Null}}catch{}
    if($client){$client.Dispose()}
    if(-not $owned.WaitForExit(10000)){Stop-Process -Id $owned.Id -Force; $owned.WaitForExit()}
    Write-Output "OWNED_HOST_EXITED=$($owned.HasExited)"; $owned.Dispose()
   }
   if($childPid) {
    $child=Get-Process -Id $childPid -ErrorAction SilentlyContinue
    if($child){if(-not $child.WaitForExit(3000)){Stop-Process -Id $childPid -Force; $child.WaitForExit()}; $child.Dispose()}
    Write-Output "OWNED_CHILD_EXITED=$(-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue))"
   }
  }
 }
 Write-Output "PASS SK1 provider modes=2 checks=$checks artifacts=$run"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
