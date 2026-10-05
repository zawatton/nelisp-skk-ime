param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference='Stop'
$id='KeymapInstall-'+[guid]::NewGuid().ToString('N');$root=Join-Path ([IO.Path]::GetTempPath()) $id
New-Item -ItemType Directory $root | Out-Null
$settings='Software\NativeIME-Tests\'+$id+'\Settings';$run='Software\NativeIME-Tests\'+$id+'\Run';$file=Join-Path $root 'keymap.conf'
[IO.File]::WriteAllText($file,"enabled = no`n[keys]`nCapsLock = LCtrl`n",[Text.UTF8Encoding]::new($false))
$args=@{Executable=$Exe;SettingsKey=$settings;RunKeyPath=$run;LocalAppData=$root;InstanceSuffix=$id;ConfigFile=$file;NoHook=$true}
$script=Join-Path $PSScriptRoot 'install-keymap.ps1';$checks=0
$oldKey=$env:NATIVEIME_REGISTRY_KEY;$oldFile=$env:NELISP_IME_KEYMAP_FILE;$oldInstance=$env:NELISP_IME_KEYMAP_INSTANCE
try {
 & $script @args -DryRun
 if(Test-Path -LiteralPath ('HKCU:\'+$run)){throw 'DryRun wrote registry'};$checks++
 & $script @args
 $first=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name Executable
 if(-not (Test-Path -LiteralPath $first)){throw 'Versioned executable missing'};$checks++
 $command=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$run) -Name NelispImeKeymap
 if($command -notmatch '--no-hook' -or $command -notmatch [regex]::Escape($settings)){throw 'Private autostart not isolated'};$checks++
 & $script @args
 $second=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name Executable
 if($second -eq $first){throw 'Update did not use a new version directory'};$checks++
 & $script @args -Rollback
 if((Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name Executable) -ne $first){throw 'Rollback did not restore previous version'};$checks++
 & $script @args -Uninstall
 if((Get-ItemProperty -LiteralPath ('HKCU:\'+$run)).PSObject.Properties['NelispImeKeymap']){throw 'Uninstall left Run entry'};$checks++
 if(-not (Test-Path -LiteralPath $file)){throw 'Uninstall removed config'};$checks++
 Write-Output "S3.4 private install/update/rollback/uninstall: PASS checks=$checks hooks=0 SendInput=0"
} finally {
 # Only stop the private instance this test created, including failure paths.
 $env:NATIVEIME_REGISTRY_KEY=$settings;$env:NELISP_IME_KEYMAP_INSTANCE=$id;$env:NELISP_IME_KEYMAP_FILE=$file
 $pidValue=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name Pid -ErrorAction SilentlyContinue
 & $Exe --stop
 if($pidValue){$owned=Get-Process -Id $pidValue -ErrorAction SilentlyContinue;if($owned){if(-not $owned.WaitForExit(5000)){if($owned.Path.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){Stop-Process -Id $owned.Id -Force;$owned.WaitForExit()}}}}
 Remove-Item -LiteralPath ('HKCU:\Software\NativeIME-Tests\'+$id) -Recurse -Force -ErrorAction SilentlyContinue
 # Resolve and check the recursive deletion target before deleting it.
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target escaped private temp directory'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
 $env:NATIVEIME_REGISTRY_KEY=$oldKey;$env:NELISP_IME_KEYMAP_FILE=$oldFile;$env:NELISP_IME_KEYMAP_INSTANCE=$oldInstance

}
