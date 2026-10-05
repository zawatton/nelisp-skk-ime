[CmdletBinding()]
param(
  [string]$EngineHostPath,
  [string]$EngineExecutablePath,
  [string]$RepositoryPath,
  [string]$ArtifactDirectory,
  [int]$ColdLoadSleepSec = 45
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $RepositoryPath) { $RepositoryPath = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
. (Join-Path $PSScriptRoot '../scripts/live-host-processes.ps1')
$assertions = 0
function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:assertions++
}
$root = 'C:\Users\Example\AppData\Local\DDSKK'
$cases = @(
  @("$root\20261005\ddskk-engine-host.exe", $true),
  @("$root\ddskk-engine-host.exe", $true),
  @('c:/users/example/appdata/local/ddskk/v1/DDSKK-ENGINE-HOST.EXE', $true),
  @("$root/one\two/../ddskk-engine-host.exe", $true),
  @("\\?\$root\v1\ddskk-engine-host.exe", $true),
  @("${root}-private\ddskk-engine-host.exe", $false),
  @("${root}2\ddskk-engine-host.exe", $false),
  @("$root\..\private\ddskk-engine-host.exe", $false),
  @('D:\worker\build\Release\ddskk-engine-host.exe', $false),
  @('D:/worker/build/Release/ddskk-engine-host.exe', $false),
  @('ddskk-engine-host.exe', $false),
  @('C:ddskk-engine-host.exe', $false),
  @('', $false), @($null, $false),
  @("$root\other.exe", $false)
)
$records = @()
foreach ($case in $cases) {
  $record = [pscustomobject]@{ Name='ddskk-engine-host.exe'; ProcessId=100 + $records.Count; ExecutablePath=$case[0] }
  $records += $record
  $selected = @(Select-LiveHostProcess @($record) ($root + '/'))
  Require (($selected.Count -eq 1) -eq $case[1]) "Wrong selection for path '$($case[0])'"
  if ($selected.Count) {
    Require ($selected[0].ProcessId -eq $record.ProcessId) 'PID changed'
    Require ($selected[0].Reason -like 'executable under live deployment root *') 'Missing reason'
  }
}
$records += [pscustomobject]@{ Name='other.exe'; ProcessId=999; ExecutablePath="$root\ddskk-engine-host.exe" }
Require (@(Select-LiveHostProcess $records $root).Count -eq 5) 'Mixed process list selected unexpected hosts'
Require (@(Select-LiveHostProcess @() $root).Count -eq 0) 'Empty process list selected hosts'
$unc = [pscustomobject]@{ Name='ddskk-engine-host.exe'; ProcessId=777; ExecutablePath='\\?\UNC\server\share\DDSKK\v1\ddskk-engine-host.exe' }
Require (@(Select-LiveHostProcess @($unc) '//SERVER/share/DDSKK/').Count -eq 1) 'UNC normalization failed'
foreach ($file in @('deploy-live.ps1','rollback-live.ps1','live-host-processes.ps1')) {
  $tokens = $null; $errors = $null
  [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "../scripts/$file"), [ref]$tokens, [ref]$errors)
  Require ($errors.Count -eq 0) "Parse errors in $file"
}
Write-Host "PASS synthetic selection cases=$($cases.Count + 1) assertions=$assertions"
if (-not $EngineHostPath -and -not $EngineExecutablePath) { return }
if (-not $EngineHostPath -or -not $EngineExecutablePath -or -not $ArtifactDirectory) {
  throw 'Integration requires EngineHostPath, EngineExecutablePath and ArtifactDirectory.'
}
$EngineHostPath = [IO.Path]::GetFullPath($EngineHostPath)
$EngineExecutablePath = [IO.Path]::GetFullPath($EngineExecutablePath)
$RepositoryPath = [IO.Path]::GetFullPath($RepositoryPath)
$ArtifactDirectory = [IO.Path]::GetFullPath($ArtifactDirectory)
$liveRoot = Join-Path $env:LOCALAPPDATA 'DDSKK'
Require (@(Select-LiveHostProcess @([pscustomobject]@{Name='ddskk-engine-host.exe'; ProcessId=0; ExecutablePath=$EngineHostPath}) $liveRoot).Count -eq 0) 'Test host must be outside live root'
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
# Reuse the harness's read-only child discovery/pipe readiness interop,
# without executing the harness or accessing any live registry/pipe.
$harnessAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'run-harness.ps1'), [ref]$tokens, [ref]$errors)
$interop = $harnessAst.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Type' }, $true)
if (-not ('NativeImeHarnessChildren' -as [type])) {
  Add-Type -TypeDefinition $interop.CommandElements[2].Value
}
$runId = [guid]::NewGuid().ToString('N')
$registryKey = "Software\NativeIME-test-$runId"
$regPath = "HKCU:\$registryKey"
$pipeName = "ddskk-test-$runId"
$saved = @{}
foreach ($name in @('NATIVEIME_REGISTRY_KEY','DDSKK_PIPE_NAME','DDSKK_USER_JISYO','LOCALAPPDATA')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$hostProcess = $null
$children = @()
try {
  $env:NATIVEIME_REGISTRY_KEY = $registryKey
  $env:DDSKK_PIPE_NAME = "\\.\pipe\$pipeName"
  $env:DDSKK_USER_JISYO = Join-Path $ArtifactDirectory 'private.jisyo'
  $env:LOCALAPPDATA = Join-Path $ArtifactDirectory 'private-appdata'
  New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null
  New-Item -Path $regPath -Force | Out-Null
  foreach ($entry in @{EngineHost=$EngineHostPath; EngineExecutable=$EngineExecutablePath; Repository=$RepositoryPath; Engine='ddskk'; UserJisyoPath=$env:DDSKK_USER_JISYO}.GetEnumerator()) {
    New-ItemProperty -Path $regPath -Name $entry.Key -Value $entry.Value -PropertyType String -Force | Out-Null
  }
  $hostProcess = Start-Process -FilePath $EngineHostPath -ArgumentList ('"{0}" "{1}"' -f $EngineExecutablePath, $RepositoryPath) -WorkingDirectory $RepositoryPath -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $ArtifactDirectory 'host.stdout.log') -RedirectStandardError (Join-Path $ArtifactDirectory 'host.stderr.log')
  Write-Host "PRIVATE_HOST pid=$($hostProcess.Id) pipe=$pipeName"
  $deadline = (Get-Date).AddSeconds(60)
  while (-not [NativeImeHarnessChildren]::WaitNamedPipeW($env:DDSKK_PIPE_NAME, 100)) {
    if ($hostProcess.HasExited -or (Get-Date) -ge $deadline) { throw 'Private host did not open its pipe' }
    Start-Sleep -Milliseconds 150
  }
  Start-Sleep -Seconds $ColdLoadSleepSec
  # Previews use the real deployment root, while the host retains private
  # appdata inherited at startup. Never write to the real root.
  $env:LOCALAPPDATA = $saved['LOCALAPPDATA']
  $manifest = Join-Path $ArtifactDirectory 'rollback.json'
  @{schema=1; previous=@{dll='preview.dll'; engine_host=$EngineHostPath; repository=$RepositoryPath; settings_exe=$null; sumi_run=$null}} | ConvertTo-Json | Set-Content -LiteralPath $manifest -Encoding UTF8
  $shell = (Get-Process -Id $PID).Path
  foreach ($scriptName in @('deploy-live.ps1','rollback-live.ps1')) {
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot "../scripts/$scriptName"),'-DryRun')
    if ($scriptName -eq 'deploy-live.ps1') { $arguments += '-HostExe' }
    else { $arguments += @('-Manifest',$manifest) }
    $output = @(& $shell @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath (Join-Path $ArtifactDirectory "$scriptName.dryrun.log")
    $output | ForEach-Object { Write-Host $_ }
    Require ($exitCode -eq 0) "$scriptName dry run failed: $exitCode"
    Require (($output -match "KEEP  : pid=$($hostProcess.Id) .*reason=executable outside live deployment root").Count -eq 1) "$scriptName did not identify the protected private host"
    Require (($output -match "would stop pid=$($hostProcess.Id)(?: |$)").Count -eq 0) "$scriptName selected private host"
    Require (-not $hostProcess.HasExited) "$scriptName stopped private host"
    Write-Host "PASS $scriptName private_pid=$($hostProcess.Id) selected=False alive=True"
  }
} finally {
  if ($hostProcess) {
    $children = @([NativeImeHarnessChildren]::Find($hostProcess.Id, [IO.Path]::GetFileName($EngineExecutablePath)) | ForEach-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    try {
      $client = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
      try {
        $client.Connect(500)
        $bytes = [Text.Encoding]::ASCII.GetBytes("SHUTDOWN`n")
        $client.Write($bytes, 0, $bytes.Length); $client.Flush()
      } finally { $client.Dispose() }
    } catch { }
    [void]$hostProcess.WaitForExit(6000)
    foreach ($owned in @($hostProcess) + $children) {
      if (-not $owned.HasExited) { $owned.Kill(); [void]$owned.WaitForExit(5000) }
      Write-Host "CLEANUP pid=$($owned.Id) exited=$($owned.HasExited)"
      Require $owned.HasExited "Owned process remains: $($owned.Id)"
    }
  }
  Remove-Item -LiteralPath $regPath -Recurse -Force -ErrorAction SilentlyContinue
  foreach ($entry in $saved.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value) }
}
Write-Host "PASS private host dry runs assertions=$assertions leftovers=0"
