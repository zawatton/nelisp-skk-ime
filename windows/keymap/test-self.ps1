param([Parameter(Mandatory)][string]$Exe,[switch]$Editor)
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Exe).Path)
$pe=[BitConverter]::ToInt32($bytes,0x3c)
$subsystem=[BitConverter]::ToUInt16($bytes,$pe+24+68)
Write-Output "PE subsystem=$subsystem expected=2"
if($subsystem -ne 2){throw 'Keymap must use the Windows GUI subsystem'}
# A GUI process with redirected handles must still return its CLI diagnostics.
$start=[Diagnostics.ProcessStartInfo]::new((Resolve-Path -LiteralPath $Exe).Path,'--self-test')
$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.EnvironmentVariables.Remove('NATIVEIME_REGISTRY_KEY');$start.EnvironmentVariables.Remove('NELISP_IME_KEYMAP_FILE')
$diagnostic=[Diagnostics.Process]::Start($start)
try {
 if(-not $diagnostic.WaitForExit(5000)){throw 'Diagnostic process timed out'}
 $stderr=$diagnostic.StandardError.ReadToEnd()
 if($diagnostic.ExitCode -ne 2 -or $stderr -notmatch 'self-test requires private file and registry overrides'){throw 'Redirected stderr or exit code missing'}
 Write-Output 'Redirected stderr: PASS checks=2'
} finally {
 if(-not $diagnostic.HasExited){$diagnostic.Kill();$diagnostic.WaitForExit()}
 $diagnostic.Dispose()
}
$privateId='KeymapTest-'+[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) $privateId
$settings='Software\NativeIME-Tests\'+$privateId
New-Item -ItemType Directory $root | Out-Null
$oldKey=$env:NATIVEIME_REGISTRY_KEY; $oldFile=$env:NELISP_IME_KEYMAP_FILE
try {
 $env:NATIVEIME_REGISTRY_KEY=$settings; $env:NELISP_IME_KEYMAP_FILE=Join-Path $root 'keymap.conf'
 $fixture="# fixture comment`nenabled = yes`nlayout = os`npass-injected = yes`nunknown = keep`n[keys]`nCapsLock = LCtrl # note`n[shortcuts]`nLAlt+Space = ime-toggle`nCtrl+Space = LWin+Space`n[exclude]`nmstsc.exe`n"
 # Unknown-line preservation is exercised by the UI; hook self-test uses a valid file.
 if(-not $Editor){$fixture=$fixture.Replace("unknown = keep`n",'')}
 [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE,$fixture,[Text.UTF8Encoding]::new($false))
 # Windows PowerShell waits for GUI executables only when they feed a pipeline.
 if($Editor){$output=@(& $Exe --editor --self-test-ui | Out-String -Stream)}else{$output=@(& $Exe --self-test | Out-String -Stream)}
 $exitCode=$LASTEXITCODE
 $output | Write-Output
 if($exitCode -ne 0){throw "self-test exit $exitCode"}
 $expected=if($Editor){'editor hidden self-test: PASS'}else{'S1.4 real hook synthetic: PASS'}
 if(-not ($output -match [regex]::Escape($expected))){throw 'Self-test stdout was not captured'}
} finally {
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target escaped the private temp root'}
 $env:NATIVEIME_REGISTRY_KEY=$oldKey; $env:NELISP_IME_KEYMAP_FILE=$oldFile
 Remove-Item -LiteralPath ('HKCU:\'+$settings) -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $root -Recurse -Force
}
