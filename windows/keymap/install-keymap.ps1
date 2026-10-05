# Per-user deployment. No DLL registration, HKLM changes or application restarts.
[CmdletBinding()]
param(
 [string]$Executable,
 [string]$SettingsKey='Software\NativeIME',
 [string]$RunKeyPath='Software\Microsoft\Windows\CurrentVersion\Run',
 [string]$LocalAppData=$env:LOCALAPPDATA,
 [string]$InstanceSuffix='',
 [string]$ConfigFile='',
 [switch]$NoHook,
 [switch]$DryRun,
 [switch]$Uninstall,
 [switch]$Rollback
)
$ErrorActionPreference='Stop'
if($Uninstall -and $Rollback){throw 'Choose Uninstall or Rollback.'}
$testMode=$SettingsKey -ne 'Software\NativeIME' -or $RunKeyPath -ne 'Software\Microsoft\Windows\CurrentVersion\Run' -or $InstanceSuffix -ne ''
if($testMode){
 if($SettingsKey -notlike 'Software\NativeIME-Tests\*' -or $RunKeyPath -notlike 'Software\NativeIME-Tests\*' -or -not $InstanceSuffix -or -not $ConfigFile -or -not $PSBoundParameters.ContainsKey('LocalAppData') -or -not $NoHook){throw 'Tests require private SettingsKey, RunKeyPath, LocalAppData, ConfigFile, InstanceSuffix and NoHook together.'} 
 if([IO.Path]::GetFullPath($LocalAppData) -eq [IO.Path]::GetFullPath($env:LOCALAPPDATA)){throw 'Test mode must not use the real LOCALAPPDATA root.'}
 $privatePrefix=[IO.Path]::GetFullPath($LocalAppData).TrimEnd('\')+'\'
 if(-not [IO.Path]::GetFullPath($ConfigFile).StartsWith($privatePrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The test config file must live under the private LocalAppData override.'}

}
if($SettingsKey.StartsWith('HK') -or $RunKeyPath.StartsWith('HK')){throw 'Registry paths must be HKCU-relative.'}
$installRoot=Join-Path ([IO.Path]::GetFullPath($LocalAppData)) 'DDSKK\keymap'
$manifestPath=Join-Path $installRoot 'rollback.json'
$settingsPath='HKCU:\'+$SettingsKey+'\Keymap';$runPath='HKCU:\'+$RunKeyPath
if($DryRun){
 Write-Output "DryRun: action=$(if($Uninstall){'uninstall'}elseif($Rollback){'rollback'}else{'install'}) root=$installRoot"
 Write-Output "DryRun: HKCU\$RunKeyPath\NelispImeKeymap; HKCU\$SettingsKey\Keymap\Executable"
 Write-Output "DryRun: no copy, registry writes, process starts or stops"
 return
}
function Read-Value([string]$Path,[string]$Name){if(Test-Path -LiteralPath $Path){$item=Get-ItemProperty -LiteralPath $Path -ErrorAction Stop;if($item.PSObject.Properties[$Name]){return [string]$item.$Name}};return $null}
function Write-OrRemove([string]$Path,[string]$Name,$Value){if($null -eq $Value){if(Test-Path -LiteralPath $Path){Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue}}else{if(-not (Test-Path -LiteralPath $Path)){New-Item -Path $Path -Force | Out-Null};New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType String -Value $Value -Force | Out-Null}}
function Args-For([string]$Verb,[string]$LaunchFile=$ConfigFile){$result=$Verb;if($testMode){$result+=' --no-hook --settings-key "'+$SettingsKey+'" --config-file "'+$LaunchFile+'" --instance "'+$InstanceSuffix+'"'}elseif($NoHook){$result+=' --no-hook'};return $result}
function Stop-Owned([string]$Exe){
 if(-not $Exe -or -not (Test-Path -LiteralPath $Exe)){return}
 $pidValue=Read-Value $settingsPath 'Pid'
 $stopper=Start-Process -FilePath $Exe -ArgumentList (Args-For '--stop') -WindowStyle Hidden -PassThru
 if(-not $stopper.WaitForExit(5000)){Stop-Process -Id $stopper.Id -Force;throw 'Stop request helper timed out.'}
 if($stopper.ExitCode -ne 0){throw "Graceful stop failed: $($stopper.ExitCode)"}
 if($pidValue -and [int]$pidValue -ne 0){
  $previous=Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
  if($previous -and -not $previous.HasExited -and $previous.Path -and [IO.Path]::GetFullPath($previous.Path) -eq [IO.Path]::GetFullPath($Exe)){
   if(-not $previous.WaitForExit(5000)){throw 'Previous resident did not stop; no process was forcibly killed.'}
  }
 }
}
function Start-Owned([string]$Exe,[string]$LaunchFile=$ConfigFile){
 if(-not $Exe){return}
 $args=Args-For '' $LaunchFile;if(-not $args){$args=' '}
 $p=Start-Process -FilePath $Exe -ArgumentList $args -WindowStyle Hidden -PassThru
 for($attempt=0;$attempt -lt 100;$attempt++){
  if($p.HasExited){throw "Resident failed to start: $($p.ExitCode)"}
  $id=Read-Value $settingsPath 'Pid';if($id -and [int]$id -eq $p.Id){return}
  Start-Sleep -Milliseconds 100
 }
 Stop-Owned $Exe;throw 'Resident did not publish its PID.'
}
if($Rollback -or $Uninstall){
 if(-not (Test-Path -LiteralPath $manifestPath)){throw 'No rollback manifest exists.'}
 $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
 if($manifest.SettingsKey -ne $SettingsKey -or $manifest.RunKeyPath -ne $RunKeyPath -or $manifest.InstanceSuffix -ne $InstanceSuffix){throw 'Manifest belongs to different settings or instance.'}
 $installed=Read-Value $settingsPath 'Executable';Stop-Owned $installed
 if($Rollback){
  Write-OrRemove $runPath 'NelispImeKeymap' $manifest.PreviousRun
  Write-OrRemove $settingsPath 'Executable' $manifest.PreviousExecutable
  Write-OrRemove $settingsPath 'File' $manifest.PreviousFile
  if($manifest.PreviousExecutable){Start-Owned $manifest.PreviousExecutable $manifest.PreviousFile}
  Write-Output 'Rollback: restored previous Run, Executable and File values.'
 }else{
  Write-OrRemove $runPath 'NelispImeKeymap' $null
  Write-OrRemove $settingsPath 'Executable' $null
  Write-Output 'Uninstall: stopped resident and removed autostart; config and versioned files retained.'
 }
 return
}
if(-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)){throw 'Executable must point to the built nelisp-ime-keymap.exe.'}
$version='1.0.0-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$destinationDir=Join-Path $installRoot $version
$destination=Join-Path $destinationDir 'nelisp-ime-keymap.exe'
$manifest=[ordered]@{Version=1;SettingsKey=$SettingsKey;RunKeyPath=$RunKeyPath;InstanceSuffix=$InstanceSuffix;InstalledExecutable=$destination;PreviousExecutable=(Read-Value $settingsPath 'Executable');PreviousRun=(Read-Value $runPath 'NelispImeKeymap');PreviousFile=(Read-Value $settingsPath 'File')}
New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
Copy-Item -LiteralPath $Executable -Destination $destination
# Persist the concrete rollback record before stopping or updating an instance.
$manifestTmp=$manifestPath+'.tmp';[IO.File]::WriteAllText($manifestTmp,($manifest|ConvertTo-Json),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $manifestTmp -Destination $manifestPath -Force
try {
 Stop-Owned $manifest.PreviousExecutable
 Write-OrRemove $settingsPath 'Executable' $destination
 if($ConfigFile){Write-OrRemove $settingsPath 'File' ([IO.Path]::GetFullPath($ConfigFile))}
 Write-OrRemove $runPath 'NelispImeKeymap' ('"'+$destination+'"'+(Args-For ''))
 Start-Owned $destination
 Write-Output "Install: started $destination; rollback manifest=$manifestPath"
} catch {
 Write-OrRemove $runPath 'NelispImeKeymap' $manifest.PreviousRun
 Write-OrRemove $settingsPath 'Executable' $manifest.PreviousExecutable
 Write-OrRemove $settingsPath 'File' $manifest.PreviousFile
 if($manifest.PreviousExecutable){Start-Owned $manifest.PreviousExecutable $manifest.PreviousFile}
 throw
}
