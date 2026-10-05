param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference='Stop'
$privateId='KeymapLifecycle-'+[guid]::NewGuid().ToString('N');$root=Join-Path ([IO.Path]::GetTempPath()) $privateId
$settings='Software\NativeIME-Tests\'+$privateId
New-Item -ItemType Directory $root | Out-Null
$oldKey=$env:NATIVEIME_REGISTRY_KEY;$oldFile=$env:NELISP_IME_KEYMAP_FILE;$oldInstance=$env:NELISP_IME_KEYMAP_INSTANCE
$processes=@();$checks=0
function Await-Value([string]$Name,$Expected){for($i=0;$i -lt 100;$i++){try{$v=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name $Name -ErrorAction Stop;if($v -eq $Expected){return}}catch{};Start-Sleep -Milliseconds 100};throw "$Name did not become $Expected"}
try {
 $env:NATIVEIME_REGISTRY_KEY=$settings;$env:NELISP_IME_KEYMAP_FILE=Join-Path $root 'keymap.conf';$env:NELISP_IME_KEYMAP_INSTANCE=$privateId
 [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE,"enabled = yes`n[keys]`nCapsLock=LCtrl`n",[Text.UTF8Encoding]::new($false))
 $p=Start-Process -FilePath $Exe -ArgumentList '--no-hook' -WindowStyle Hidden -PassThru;$processes+=$p
 Await-Value Pid $p.Id;Await-Value RuleCount 1;Await-Value Status 'ok';$checks+=3
 $second=Start-Process -FilePath $Exe -ArgumentList '--no-hook' -WindowStyle Hidden -PassThru;$processes+=$second;if(-not $second.WaitForExit(5000)){throw 'second instance hung'};if($second.ExitCode -ne 10){throw 'second instance accepted'};$checks++
 [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE,"enabled = yes`n[keys]`nCapsLock=LCtrl`nA=B`nBadKey=C`n",[Text.UTF8Encoding]::new($false))
 Await-Value RuleCount 2;Await-Value Status 'error';$checks+=2
 $errors=Get-ItemPropertyValue -LiteralPath ('HKCU:\'+$settings+'\Keymap') -Name Errors;if(-not ($errors -match 'line 5:')){throw 'line number missing'};$checks++
 # An exclusive writer forces the resident to retain the old snapshot and retry.
 $locked=[IO.File]::Open($env:NELISP_IME_KEYMAP_FILE,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try {
  $bytes=[Text.Encoding]::UTF8.GetBytes("enabled = yes`n[keys]`nCapsLock=LCtrl`nA=B`nC=D`n")
  $locked.SetLength(0);$locked.Write($bytes,0,$bytes.Length);$locked.Flush()
  Start-Sleep -Milliseconds 600
  Await-Value RuleCount 2;Await-Value Status 'error';$checks+=2
 } finally {$locked.Dispose()}
 Await-Value RuleCount 3;Await-Value Status 'ok';$checks+=2
 & $Exe --stop;if($LASTEXITCODE -ne 0){throw 'stop failed'};if(-not $p.WaitForExit(5000)){throw 'graceful stop timeout'};Await-Value Pid 0;$checks+=2
 $p=Start-Process -FilePath $Exe -ArgumentList '--no-hook' -WindowStyle Hidden -PassThru;$processes+=$p;Await-Value Pid $p.Id;Stop-Process -Id $p.Id -Force;$p.WaitForExit();$checks++
 $p=Start-Process -FilePath $Exe -ArgumentList '--no-hook' -WindowStyle Hidden -PassThru;$processes+=$p;Await-Value Pid $p.Id;Await-Value RuleCount 3;$checks+=2
 & $Exe --stop;if(-not $p.WaitForExit(5000)){throw 'recovery stop timeout'};$checks++
 Write-Output "S2.3 private lifecycle: PASS checks=$checks hooks=0 SendInput=0"
} finally {
 foreach($p in $processes){if(-not $p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}}
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target escaped the private temp root'}
 $env:NATIVEIME_REGISTRY_KEY=$oldKey;$env:NELISP_IME_KEYMAP_FILE=$oldFile;$env:NELISP_IME_KEYMAP_INSTANCE=$oldInstance
 Remove-Item -LiteralPath ('HKCU:\'+$settings) -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $root -Recurse -Force
}
