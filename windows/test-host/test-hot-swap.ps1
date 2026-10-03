[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$EngineHostPath,
  [Parameter(Mandatory=$true)][string]$EngineExecutablePath,
  [Parameter(Mandatory=$true)][string]$BuildDirectory,
  [string]$RepositoryPath = '',
  [switch]$StressKeys
)
$ErrorActionPreference = 'Stop'
if (-not $RepositoryPath) { $RepositoryPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..')) }
$id = [guid]::NewGuid().ToString('N')
$key = "Software\NativeIME-test-$id"
$reg = "HKCU:\$key"
$pipe = "nativeime-swap-$id"
$hostProcess = $null
$client = $null
$saved = @{}
foreach ($name in @('NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','NELISP_IME_ENGINE',
    'DDSKK_USER_JISYO','LOCALAPPDATA','DDSKK_SKKSERV_ENABLE','DDSKK_DICTIONARY_FILES')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Request([string]$request, [int]$timeout=1000) {
  $script:requestCount++
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $bytes = [Text.Encoding]::ASCII.GetBytes($request + "`n")
  $client.Write($bytes, 0, $bytes.Length)
  $buffer = New-Object byte[] 8192
  $pending = $client.ReadAsync($buffer, 0, $buffer.Length)
  if (-not $pending.Wait($timeout)) { throw "Timed out: $request (request=$script:requestCount elapsed_ms=$($watch.Elapsed.TotalMilliseconds))" }
  $count = $pending.Result
  if ($count -eq 0) { throw "Disconnected: $request" }
  $watch.Stop()
  $script:lastLatency = $watch.Elapsed.TotalMilliseconds
  [Text.Encoding]::ASCII.GetString($buffer,0,$count)
}
function Require($condition, [string]$message) { if (-not $condition) { throw $message } }
function AwaitEngine([string]$engine) {
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  $maximum = 0.0
  $requests = 0
  do {
    $current = Request 'ENGINE CURRENT'
    $maximum = [Math]::Max($maximum, $script:lastLatency)
    $requests++
    # Real session transactions must continue to use the old child while
    # its replacement loads; sampling only a host-local ACK proves less.
    if ($StressKeys) {
      $state = Request 'SESSION latency KEY 97'
      Require ($state.StartsWith('STATE ')) "Key lost during switch: $state"
      $maximum = [Math]::Max($maximum, $script:lastLatency)
      $reset = Request 'SESSION latency RESET'
      Require ($reset.StartsWith('STATE ')) "Reset lost during switch: $reset"
      $maximum = [Math]::Max($maximum, $script:lastLatency)
      $requests += 2
    }
    if ($requests % 60 -eq 0) { Write-Host ("PROGRESS current={0} requests={1} max_ms={2:F3}" -f $current,$requests,$maximum) }
    Require ($maximum -lt 1000) "Switch latency exceeded 1 second: $maximum ms"
    if ($current -eq "ENGINE $engine") { break }
    Start-Sleep -Milliseconds 30
  } while ([DateTime]::UtcNow -lt $deadline)
  Require ($current -eq "ENGINE $engine") "Expected $engine; got $current"
  Write-Output ("SWITCH current={0} requests={1} max_ms={2:F3}" -f $engine,$requests,$maximum)
}
try {
  New-Item -Path $reg -Force | Out-Null
  New-ItemProperty -Path $reg -Name Engine -Value ddskk -PropertyType String | Out-Null
  New-ItemProperty -Path $reg -Name DictionaryFiles -Value (Join-Path $PSScriptRoot 'data/behavior-jisyo.utf8') -PropertyType String | Out-Null
  New-ItemProperty -Path $reg -Name SkkServEnable -Value 0 -PropertyType DWord | Out-Null
  $env:NATIVEIME_REGISTRY_KEY = $key
  $env:DDSKK_PIPE_NAME = "\\.\pipe\$pipe"
  $env:DDSKK_USER_JISYO = Join-Path $BuildDirectory "swap-$id.jisyo"
  $env:LOCALAPPDATA = $BuildDirectory
  Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue
  Remove-Item Env:DDSKK_DICTIONARY_FILES -ErrorAction SilentlyContinue
  $env:DDSKK_SKKSERV_ENABLE = '0'
  $hostProcess = Start-Process -FilePath $EngineHostPath -ArgumentList @("`"$EngineExecutablePath`"", "`"$RepositoryPath`"") -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $BuildDirectory "host-$id.stderr")
  $client = New-Object IO.Pipes.NamedPipeClientStream('.', $pipe, [IO.Pipes.PipeDirection]::InOut, [IO.Pipes.PipeOptions]::Asynchronous)
  $client.Connect(30000)
  $client.ReadMode = [IO.Pipes.PipeTransmissionMode]::Message
  Require ((Request 'ENGINE CURRENT' 100000) -eq 'ENGINE ddskk') 'Initial ddskk readiness failed'
  Require ((Request 'SESSION latency KEY 97' 100000).StartsWith('STATE ')) 'Initial input warm-up failed'
  Write-Output ("WARMUP key_ms={0:F3}" -f $script:lastLatency)
  Require ((Request 'SESSION latency RESET' 100000).StartsWith('STATE ')) 'Initial session reset failed'
  Write-Output 'READY ddskk'
  $old = Request 'DIAG CHILD-PID'
  $reply = Request 'ENGINE SWITCH lattice'
  Require ($reply -eq 'OK SWITCHING lattice') "Unexpected switch reply: $reply"
  Write-Output ("ACK {0} ms={1:F3}" -f $reply,$script:lastLatency)
  AwaitEngine lattice
  Require ((Request 'DIAG CHILD-PID') -ne $old) 'Switch retained the child PID'
  $old = Request 'DIAG CHILD-PID'
  $reply = Request 'ENGINE RELOAD'
  Require ($reply -eq 'OK RELOADING') "Unexpected reload reply: $reply"
  Write-Output ("ACK {0} ms={1:F3}" -f $reply,$script:lastLatency)
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  do { Start-Sleep -Milliseconds 100; $new = Request 'DIAG CHILD-PID' }
  while ($new -eq $old -and [DateTime]::UtcNow -lt $deadline)
  Require ($new -ne $old) 'Reload did not replace the child'
  Write-Output "RELOAD old=$old new=$new"
  $childPid = [int]$new.Substring(4)
  Stop-Process -Id $childPid -Force
  # Avoid a transaction on the dead child. The management endpoint remains
  # available on this same connection throughout automatic recovery.
  $deadline = [DateTime]::UtcNow.AddSeconds(120)
  do { Start-Sleep -Milliseconds 100; $recovered = Request 'DIAG CHILD-PID' }
  while ($recovered -eq $new -and [DateTime]::UtcNow -lt $deadline)
  Require ($recovered -ne $new) 'Child death was not recovered'
  Require ((Request 'ENGINE CURRENT') -eq 'ENGINE lattice') 'Recovery changed engine'
  Write-Output "RECOVERY killed=$new recovered=$recovered same_connection=True"
  Set-ItemProperty -Path $reg -Name Engine -Value passthrough
  AwaitEngine passthrough
  Require ((Request 'ENGINE SWITCH invalid') -eq 'ERR ENGINE') 'Invalid id accepted'
  Require ((Request 'SHUTDOWN') -eq 'OK') 'Shutdown failed'
  Require ($hostProcess.WaitForExit(5000)) 'Shutdown did not terminate host'
  Write-Output 'PASS hot-swap, reload, death recovery, registry notification, shutdown'
} finally {
  if ($client) { $client.Dispose() }
  if ($hostProcess -and -not $hostProcess.HasExited) {
    Stop-Process -Id $hostProcess.Id -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $reg -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key,$entry.Value) }
}
