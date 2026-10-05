[CmdletBinding()]
param([Parameter(Mandatory)][string]$KeymapExe,[Parameter(Mandatory)][string]$IndicatorExe)
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SumiEditorPrivateProbe {
 [StructLayout(LayoutKind.Sequential)] struct CopyData { public UIntPtr tag; public int size; public IntPtr data; }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent,IntPtr after,string cls,string title);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,out uint pid);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int command);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool SetProp(IntPtr hwnd,string name,IntPtr data);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr RemoveProp(IntPtr hwnd,string name);
 [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr hwnd,uint msg,IntPtr wp,IntPtr lp,uint flags,uint timeout,out UIntPtr result);
 public static ulong Query(IntPtr hwnd,int vk,int scan,int ext){
  IntPtr payload=Marshal.AllocHGlobal(12),block=Marshal.AllocHGlobal(Marshal.SizeOf<CopyData>());
  try {Marshal.Copy(new[]{vk,scan,ext},0,payload,3);Marshal.StructureToPtr(new CopyData{tag=(UIntPtr)0x534b5131,size=12,data=payload},block,false);
   UIntPtr result; if(SendMessageTimeout(hwnd,0x4a,IntPtr.Zero,block,2,1000,out result)==IntPtr.Zero)throw new Exception("Query timed out");return result.ToUInt64();
  } finally {Marshal.FreeHGlobal(payload);Marshal.FreeHGlobal(block);}
 }
}
'@
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$dir=Join-Path $root ('build/validation/sumi-settings/sn4-e2e-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir -Force | Out-Null
$key='Software\NativeIME-Tests\SN4-'+[guid]::NewGuid().ToString('N')
$saved=@{};$children=@();$captureWindow=[IntPtr]::Zero;$checks=0
foreach($n in @('NATIVEIME_REGISTRY_KEY','DDSKK_SETTINGS_KEY','DDSKK_PIPE_NAME','NELISP_IME_KEYMAP_FILE','NELISP_IME_INPUT_RULES','NELISP_IME_KEYMAP_INSTANCE','DDSKK_ALLOW_MULTIPLE_INSTANCES')){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
function Start-Private([string]$exe,[string]$arguments,[string]$label,[bool]$interactive=$false){
 $style=if($interactive){'Normal'}else{'Hidden'}
 $p=Start-Process -FilePath ([IO.Path]::GetFullPath($exe)) -ArgumentList $arguments -WindowStyle $style -PassThru -RedirectStandardOutput (Join-Path $dir ($label+'.out')) -RedirectStandardError (Join-Path $dir ($label+'.err'))
 $script:children+=$p;return $p
}
function Owned-Window([int]$ProcessId,[string]$Class){
 $w=[IntPtr]::Zero
 do {$w=[SumiEditorPrivateProbe]::FindWindowEx([IntPtr]::Zero,$w,$Class, $(if($Class -eq 'gdkSurfaceToplevel'){'NeLisp IME 設定'}else{$null}));[uint32]$owner=0;if($w -ne [IntPtr]::Zero){[void][SumiEditorPrivateProbe]::GetWindowThreadProcessId($w,[ref]$owner)};if($owner -eq $ProcessId -and ($Class -ne 'gdkSurfaceToplevel' -or [SumiEditorPrivateProbe]::IsWindowVisible($w))){return $w}}while($w -ne [IntPtr]::Zero)
 return [IntPtr]::Zero
}
function Assert([bool]$condition,[string]$label){if(-not $condition){throw "FAIL $label"};$script:checks++;Write-Output "PASS $label"}
try {
 $env:NATIVEIME_REGISTRY_KEY=$key;$env:DDSKK_SETTINGS_KEY=$key;$env:DDSKK_PIPE_NAME='\\.\pipe\sn4-'+[guid]::NewGuid().ToString('N')
 $env:NELISP_IME_KEYMAP_INSTANCE='SN4-'+[guid]::NewGuid().ToString('N');$env:DDSKK_ALLOW_MULTIPLE_INSTANCES='1'
 $env:NELISP_IME_KEYMAP_FILE=Join-Path $dir 'keymap.conf';$env:NELISP_IME_INPUT_RULES=Join-Path $dir 'input-rules.conf'
 [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE,"# private fixture`nenabled = yes`nlayout = os`npass-injected = yes`n[keys]`nA = B # keep mapping comment`n",[Text.UTF8Encoding]::new($false))
 $remapper=Start-Private $KeymapExe '--no-hook' 'remapper'
 $timer=[Diagnostics.Stopwatch]::StartNew();$hwnd=[IntPtr]::Zero
 while($timer.ElapsedMilliseconds -lt 10000 -and $hwnd -eq [IntPtr]::Zero){$hwnd=Owned-Window $remapper.Id 'NelispImeKeymapResident';Start-Sleep -Milliseconds 20}
 Assert ($hwnd -ne [IntPtr]::Zero) 'private-remapper-started'
 Assert ([SumiEditorPrivateProbe]::Query($hwnd,65,0x1e,0) -eq 0x11010042) 'resident-before-edit-A-to-B'
 $editor=Start-Private $IndicatorExe '--editor-apply-selftest' 'edit'
 Assert ($editor.WaitForExit(15000) -and $editor.ExitCode -eq 0) 'Sumi-GTK-edit-save-completed'
 $timer.Restart();$result=0
 while($timer.ElapsedMilliseconds -lt 10000){$result=[SumiEditorPrivateProbe]::Query($hwnd,65,0x1e,0);if($result -eq 0x11010043){break};Start-Sleep -Milliseconds 50}
 Assert ($result -eq 0x11010043) 'resident-watcher-live-A-to-C'
 Assert ([IO.File]::ReadAllText($env:NELISP_IME_KEYMAP_FILE).Contains('# keep mapping comment')) 'mapping-comment-kept'
 # Capture is explicitly restricted to the foreground interactive inspector.
 $sumi=Start-Private $IndicatorExe '--editor' 'surface' $true
 $timer.Restart()
 while($timer.ElapsedMilliseconds -lt 10000 -and $captureWindow -eq [IntPtr]::Zero){$captureWindow=Owned-Window $sumi.Id 'gdkSurfaceToplevel';Start-Sleep -Milliseconds 20}
 if($captureWindow -eq [IntPtr]::Zero){Write-Output "surface pid=$($sumi.Id) exited=$($sumi.HasExited)";Get-Content (Join-Path $dir 'surface.err')}
 Assert ($captureWindow -ne [IntPtr]::Zero) 'owned-Sumi-inspector-window'
 [void][SumiEditorPrivateProbe]::ShowWindow($captureWindow,5)
 [void][SumiEditorPrivateProbe]::SetForegroundWindow($captureWindow);Start-Sleep -Milliseconds 100
 Write-Output "FOCUS owned=$captureWindow foreground=$([SumiEditorPrivateProbe]::GetForegroundWindow())"
 Assert ([SumiEditorPrivateProbe]::GetForegroundWindow() -eq $captureWindow) 'inspector-foreground'
 Assert ([SumiEditorPrivateProbe]::SetProp($captureWindow,'NelispImeKeymapCapture',[IntPtr]1)) 'capture-suspend-property'
 [UIntPtr]$ack=[UIntPtr]::Zero
 $sent=[SumiEditorPrivateProbe]::SendMessageTimeout($hwnd,0x8004,[IntPtr]::Zero,$captureWindow,2,200,[ref]$ack)
 Assert ($sent -ne [IntPtr]::Zero -and $ack.ToUInt64() -eq 1) 'resident-held-output-release-handshake'
 Assert ([SumiEditorPrivateProbe]::Query($hwnd,65,0x1e,0) -eq 0x10000000) 'capture-exclusion-bypasses-remapping'
 [void][SumiEditorPrivateProbe]::RemoveProp($captureWindow,'NelispImeKeymapCapture');$timer.Restart()
 while($timer.ElapsedMilliseconds -lt 3000){$result=[SumiEditorPrivateProbe]::Query($hwnd,65,0x1e,0);if($result -eq 0x11010043){break};Start-Sleep -Milliseconds 20}
 Assert ($result -eq 0x11010043) 'capture-exclusion-removed-remapping-resumes'
 Assert ([SumiEditorPrivateProbe]::Query($hwnd,256,0,0) -eq 0) 'malformed-query-rejected'
 Write-Output "verify-sumi-editor-e2e: $checks PASS, 0 FAIL; hooks=0 SendInput=0; real resident watcher and decision snapshot"
} finally {
 if($captureWindow -ne [IntPtr]::Zero){[void][SumiEditorPrivateProbe]::RemoveProp($captureWindow,'NelispImeKeymapCapture')}
 foreach($p in $children){if(-not $p.HasExited){Stop-Process -Id $p.Id -Force};$p.WaitForExit();Write-Output "OWNED_EXIT pid=$($p.Id) exited=$($p.HasExited)"}
 Remove-Item -LiteralPath ('HKCU:\'+$key) -Recurse -Force -ErrorAction SilentlyContinue
 foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n])}
}
