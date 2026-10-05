param([string]$IndicatorExe = (Join-Path $PSScriptRoot '../target/sumi-skk-ui.exe'))
$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SumiEditorProbe {
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern uint RegisterWindowMessage(string name);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out UIntPtr result);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
 [DllImport("dwmapi.dll")] public static extern int DwmFlush();
}
'@
$id = [guid]::NewGuid().ToString('N')
$key = "Software\NativeIME-Tests\SN4-$id"
$dir = Join-Path $env:TEMP "sumi-editor-resident-$id"
$saved = @{}
foreach ($name in @('NATIVEIME_REGISTRY_KEY','DDSKK_SETTINGS_KEY','DDSKK_PIPE_NAME','DDSKK_ALLOW_MULTIPLE_INSTANCES','NELISP_IME_INPUT_RULES','NELISP_IME_KEYMAP_FILE')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$children = @()
function Start-Ui([string]$label, [string]$arguments) {
 $options = @{ FilePath=[IO.Path]::GetFullPath($IndicatorExe); WindowStyle='Hidden'; PassThru=$true; RedirectStandardOutput=(Join-Path $dir "$label.out"); RedirectStandardError=(Join-Path $dir "$label.err") }
 if ($arguments) { $options.ArgumentList = $arguments }
 $p = Start-Process @options
 $script:children += $p
 return $p
}
function Wait-Visible([int]$ProcessId, $watch) {
 while ($watch.ElapsedMilliseconds -lt 15000) {
  $hwnd = [IntPtr]::Zero
  do {
   $hwnd = [SumiEditorProbe]::FindWindowEx([IntPtr]::Zero,$hwnd,'gdkSurfaceToplevel','NeLisp IME 設定')
   [uint32]$owner = 0
   if ($hwnd -ne [IntPtr]::Zero) { [void][SumiEditorProbe]::GetWindowThreadProcessId($hwnd,[ref]$owner) }
   if ($owner -eq $ProcessId -and [SumiEditorProbe]::IsWindowVisible($hwnd)) {
    [void][SumiEditorProbe]::DwmFlush()
    return $watch.ElapsedMilliseconds
   }
  } while ($hwnd -ne [IntPtr]::Zero)
  Start-Sleep -Milliseconds 10
 }
 throw "No visible settings frame for owned process $ProcessId"
}
try {
 New-Item -ItemType Directory -Path $dir | Out-Null
 $env:NATIVEIME_REGISTRY_KEY = $key
 $env:DDSKK_SETTINGS_KEY = $key
 $env:DDSKK_PIPE_NAME = "\\.\pipe\sumi-editor-resident-$id"
 $env:DDSKK_ALLOW_MULTIPLE_INSTANCES = '1'
 $env:NELISP_IME_INPUT_RULES = Join-Path $dir 'input-editor.conf'
 $env:NELISP_IME_KEYMAP_FILE = Join-Path $dir 'keymap.conf'
 $watch = [Diagnostics.Stopwatch]::StartNew()
 $standalone = Start-Ui 'standalone' '--editor'
 $cold = Wait-Visible $standalone.Id $watch
 Write-Host "MEASURE spawn-to-visible-frame-ms=$cold"
 Stop-Process -Id $standalone.Id -Force
 $resident = Start-Ui 'resident' ''
 $watch.Restart()
 $endpoint = [IntPtr]::Zero
 while ($watch.ElapsedMilliseconds -lt 10000 -and $endpoint -eq [IntPtr]::Zero) {
  $endpoint = [SumiEditorProbe]::FindWindowEx([IntPtr](-3),[IntPtr]::Zero,'NeLispSumiSettingsV1',$key)
  if ($endpoint -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 10 }
 }
 if ($endpoint -eq [IntPtr]::Zero) { throw 'FAIL resident settings endpoint absent' }
 [uint32]$owner=0
 [void][SumiEditorProbe]::GetWindowThreadProcessId($endpoint,[ref]$owner)
 if ($owner -ne $resident.Id) { throw 'FAIL endpoint ownership' }
 $message = [SumiEditorProbe]::RegisterWindowMessage('NativeIME.Sumi.ShowEditor.v1')
 $watch.Restart()
 [UIntPtr]$ack = [UIntPtr]::Zero
 $sent = [SumiEditorProbe]::SendMessageTimeout($endpoint,$message,[IntPtr]::Zero,[IntPtr]::Zero,2,500,[ref]$ack)
 if ($sent -eq [IntPtr]::Zero -or $ack.ToUInt64() -ne 1) { throw 'FAIL resident acknowledgment' }
 $warm = Wait-Visible $resident.Id $watch
 $launcher = Start-Ui 'launcher' '--editor'
 if (-not $launcher.WaitForExit(5000) -or $launcher.ExitCode -ne 0) { throw 'FAIL editor launcher resident routing' }
 Write-Host 'PASS editor-launcher-exits-after-resident-acknowledgment'

 Write-Host "MEASURE resident-request-to-visible-frame-ms=$warm"
 Write-Host 'PASS private-editor-resident-request-same-process'
 $sent = [SumiEditorProbe]::SendMessageTimeout($endpoint,$message,[IntPtr]::Zero,[IntPtr]::Zero,2,500,[ref]$ack)
 if ($sent -eq [IntPtr]::Zero -or $ack.ToUInt64() -ne 1) { throw 'FAIL repeat acknowledgment' }
 Write-Host 'PASS repeat-resident-request'
 $wrong = [SumiEditorProbe]::FindWindowEx([IntPtr](-3),[IntPtr]::Zero,'NeLispSumiSettingsV1',"$key-other")
 if ($wrong -ne [IntPtr]::Zero) { throw 'FAIL identity isolation' }
 Write-Host 'PASS private-identity-isolation'
 Write-Host 'verify-resident-editor: 4 PASS, 0 FAIL'
} finally {
 foreach ($p in $children) { $p.Refresh(); if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }; $p.WaitForExit() }
 foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
 foreach ($f in @('standalone.out','standalone.err','resident.out','resident.err','launcher.out','launcher.err','input-editor.conf','keymap.conf')) { Remove-Item -LiteralPath (Join-Path $dir $f) -ErrorAction SilentlyContinue }
 [IO.Directory]::Delete($dir)
}
