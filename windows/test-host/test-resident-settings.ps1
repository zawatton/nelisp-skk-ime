[CmdletBinding()]
param(
 [string]$IndicatorExe = (Join-Path $PSScriptRoot '../../sumi-ui/target/sumi-skk-ui.exe'),
 [string]$BuildDirectory = (Join-Path $PSScriptRoot '../../build/settings-request'),
 [string]$TsfHostExe = (Join-Path $PSScriptRoot '../../build/w/Release/tsf-host.exe'),
 [string]$DllPath = (Join-Path $PSScriptRoot '../../build/w/Release/ddskk-ime.dll'),
 [string]$Compiler = 'g++'
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
New-Item -ItemType Directory -Path $BuildDirectory -Force | Out-Null
$source = Get-Content -Raw -LiteralPath (Join-Path $root 'windows/src/text_service.cpp')
$body = [regex]::Match($source, '(?s)void TextService::ShowSettings\(\) \{.*?\r?\n\}').Value
if (-not $body) { throw 'ShowSettings body missing' }
$constants = [regex]::Matches($source, 'static const wchar_t k(?:SettingsWindowTitle|GtkToplevelClass)\[\][^;]*;') | ForEach-Object { $_.Value }
[IO.File]::WriteAllText((Join-Path $BuildDirectory 'ShowSettings.inc'), (($constants -join "`n") + "`n" + $body), [Text.UTF8Encoding]::new($false))
$probe = Join-Path $BuildDirectory 'settings-request-probe.exe'
& $Compiler -std=c++20 -Wall -Wextra -I $BuildDirectory (Join-Path $PSScriptRoot 'settings-request-probe.cpp') -o $probe -ladvapi32 -lshell32 -lole32
if ($LASTEXITCODE -ne 0) { throw 'Probe build failed' }
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CoreSettingsProbe {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
}
'@
$id = [guid]::NewGuid().ToString('N')
$key = "Software\NativeIME-Tests\SN1-$id"
$owned = @(); $assertions = 0; $saved = @{}
foreach ($name in @('NATIVEIME_REGISTRY_KEY','DDSKK_SETTINGS_KEY','DDSKK_PIPE_NAME','DDSKK_ALLOW_MULTIPLE_INSTANCES','NELISP_IME_INPUT_RULES','NELISP_IME_KEYMAP_FILE','DDSKK_HARNESS_DLL_PATH','NELISP_IME_DISABLE_HOST_SPAWN','DDSKK_USER_JISYO')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$toolbarKey = "Software\NativeIME-test-SN1-$id"
function Require([bool]$ok, [string]$name) { if (-not $ok) { throw "FAIL $name" }; $script:assertions++; Write-Host "PASS $name" }
function Start-Owned([string]$exe, [string]$label, [string]$arg = '') {
 $options = @{FilePath=$exe; WindowStyle='Hidden'; PassThru=$true; RedirectStandardOutput=(Join-Path $BuildDirectory "$id-$label.out"); RedirectStandardError=(Join-Path $BuildDirectory "$id-$label.err")}
 if ($arg) { $options.ArgumentList=$arg }
 $p=Start-Process @options; $script:owned += $p; return $p
}
function Stop-Owned {
 foreach ($p in $script:owned) { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }; $p.WaitForExit() }
 $script:owned=@()
}
function Wait-Endpoint {
 $watch=[Diagnostics.Stopwatch]::StartNew()
 do {
  $h=[CoreSettingsProbe]::FindWindowEx([IntPtr](-3),[IntPtr]::Zero,'NeLispSumiSettingsV1',$env:NATIVEIME_REGISTRY_KEY)
  if ($h -ne [IntPtr]::Zero) { return $h }
  Start-Sleep -Milliseconds 10
 } while ($watch.ElapsedMilliseconds -lt 15000)
 throw 'Endpoint timed out'
}
function Wait-Window([int]$ProcessId) {
 $watch=[Diagnostics.Stopwatch]::StartNew()
 do {
  $h=[IntPtr]::Zero
  do {
   $h=[CoreSettingsProbe]::FindWindowEx([IntPtr]::Zero,$h,'gdkSurfaceToplevel','NeLisp IME 設定')
   [uint32]$owner=0
   if ($h -ne [IntPtr]::Zero) { [void][CoreSettingsProbe]::GetWindowThreadProcessId($h,[ref]$owner) }
   if ($owner -eq $ProcessId -and [CoreSettingsProbe]::IsWindowVisible($h)) { return $h }
  } while ($h -ne [IntPtr]::Zero)
  Start-Sleep -Milliseconds 10
 } while ($watch.ElapsedMilliseconds -lt 15000)
 throw "Settings window timed out for owned process $ProcessId"
}
function Request([string]$label, [int]$expectedLaunches) {
 $p=Start-Owned $probe "request-$label"
 if (-not $p.WaitForExit(10000)) { throw 'Core request timed out' }
 $lines=@(Get-Content -LiteralPath (Join-Path $BuildDirectory "$id-request-$label.out"))
 $lines | ForEach-Object { Write-Host $_ }
 foreach ($line in $lines) {
  if ($line -match '^SPAWN pid=(\d+)$') { $script:owned += Get-Process -Id ([int]$Matches[1]) }
 }
 Require ($p.ExitCode -eq 0 -and ($lines -contains "REQUEST launches=$expectedLaunches")) "$label-launch-path"
 return @($lines | Where-Object { $_ -match '^SPAWN pid=(\d+)$' } | ForEach-Object { [int]($_ -replace '^SPAWN pid=','') })
}
try {
 $env:NATIVEIME_REGISTRY_KEY=$key; $env:DDSKK_SETTINGS_KEY=$key
 $env:DDSKK_PIPE_NAME="\\.\pipe\sumi-core-$id"
 # Verify automatic private-instance isolation too; no shared GApplication activation.
 $env:DDSKK_ALLOW_MULTIPLE_INSTANCES=$null
 $env:NELISP_IME_INPUT_RULES=Join-Path $BuildDirectory "$id-input-rules.conf"
 $env:NELISP_IME_KEYMAP_FILE=Join-Path $BuildDirectory "$id-keymap.conf"
 New-Item -Path "HKCU:\$key" -Force | Out-Null
 New-ItemProperty -Path "HKCU:\$key" -Name SettingsExe -Value ([IO.Path]::GetFullPath($IndicatorExe)) -PropertyType String | Out-Null
 $resident=Start-Owned ([IO.Path]::GetFullPath($IndicatorExe)) 'resident'
 [void](Wait-Endpoint)
 [void](Request 'resident' 0)
 $window=Wait-Window $resident.Id
 Require ($window -ne [IntPtr]::Zero) 'resident-same-process-visible'
 [void](Request 'repeat' 0)
 [void][CoreSettingsProbe]::PostMessage($window,16,[IntPtr]::Zero,[IntPtr]::Zero)
 $watch=[Diagnostics.Stopwatch]::StartNew()
 while ([CoreSettingsProbe]::IsWindowVisible($window) -and $watch.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 10 }
 [void](Request 'reopen' 0)
 Require ((Wait-Window $resident.Id) -ne [IntPtr]::Zero) 'resident-close-reopen'
 Stop-Owned
 $spawn=@(Request 'absent-fallback' 1)
 Require ($spawn.Count -eq 1 -and (Wait-Window $spawn[0]) -ne [IntPtr]::Zero) 'fallback-visible-owned-child'
 [void](Wait-Endpoint)
 [void](Request 'fallback-reuse' 0)
 Stop-Owned
 $reject=Start-Owned $probe 'reject' '--reject'
 [void](Wait-Endpoint)
 $spawn=@(Request 'rejected-fallback' 1)
 Require ($spawn.Count -eq 1 -and (Wait-Window $spawn[0]) -ne [IntPtr]::Zero) 'rejected-fallback-visible-owned-child'
 Stop-Owned
 $hung=Start-Owned $probe 'hung' '--hang'
 [void](Wait-Endpoint)
 $spawn=@(Request 'timeout-fallback' 1)
 Require ($spawn.Count -eq 1 -and (Wait-Window $spawn[0]) -ne [IntPtr]::Zero) 'timeout-fallback-visible-owned-child'
 Stop-Owned
 # No engine transaction is part of opening settings. Drive the actual
 # DLL toolbar item in the isolated TSF host with host spawning disabled.
 $env:NATIVEIME_REGISTRY_KEY=$toolbarKey; $env:DDSKK_SETTINGS_KEY=$toolbarKey
 $env:DDSKK_PIPE_NAME="\\.\pipe\ddskk-test-SN1-$id"
 $env:DDSKK_USER_JISYO=Join-Path $BuildDirectory "$id-user-jisyo"
 $env:DDSKK_HARNESS_DLL_PATH=[IO.Path]::GetFullPath($DllPath)
 $env:NELISP_IME_DISABLE_HOST_SPAWN='1'
 New-Item -Path "HKCU:\$toolbarKey" -Force | Out-Null
 New-ItemProperty -Path "HKCU:\$toolbarKey" -Name SettingsExe -Value ([IO.Path]::GetFullPath($IndicatorExe)) -PropertyType String | Out-Null
 $resident=Start-Owned ([IO.Path]::GetFullPath($IndicatorExe)) 'toolbar-resident'
 [void](Wait-Endpoint)
 $hostProcess=Start-Owned ([IO.Path]::GetFullPath($TsfHostExe)) 'toolbar-host' 'SETTINGS WAIT500'
 if (-not $hostProcess.WaitForExit(15000)) { throw 'Toolbar host timed out' }
 $lines=@(Get-Content -LiteralPath (Join-Path $BuildDirectory "$id-toolbar-host.out"))
 $lines | ForEach-Object { Write-Host $_ }
 Require ($hostProcess.ExitCode -eq 0 -and [bool]($lines -match 'ToolbarSettings.*00000000')) 'real-toolbar-settings-callback'
 Require ((Wait-Window $resident.Id) -ne [IntPtr]::Zero) 'real-toolbar-resident-same-process'
 Write-Host "verify-core-resident-settings: $assertions PASS, 0 FAIL"
} finally {
 Stop-Owned
 if (Test-Path -LiteralPath "HKCU:\$key") { Remove-Item -LiteralPath "HKCU:\$key" -Force }
 if (Test-Path -LiteralPath "HKCU:\$toolbarKey") { Remove-Item -LiteralPath "HKCU:\$toolbarKey" -Recurse -Force }
 foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
 Get-ChildItem -LiteralPath $BuildDirectory -Filter "$id-*" -File | Remove-Item -Force
}
