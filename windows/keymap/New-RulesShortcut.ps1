[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$Executable,
 [string]$Directory=''
)
$ErrorActionPreference='Stop'
$Executable=[IO.Path]::GetFullPath($Executable)
if(-not (Test-Path -LiteralPath $Executable -PathType Leaf)){throw 'Executable must exist.'}
if(-not $Directory){$Directory=Join-Path ([Environment]::GetFolderPath('Programs')) 'NativeIME'}
New-Item -ItemType Directory -Path $Directory -Force | Out-Null
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([IO.Path]::GetFullPath($Directory)) 'Input Rules.lnk'))
$shortcut.TargetPath=$Executable
$shortcut.Arguments='--rules'
$shortcut.WorkingDirectory=Split-Path -Parent $Executable
$shortcut.Description='NativeIME input rules editor'
$shortcut.Save()
Write-Output (Join-Path $Directory 'Input Rules.lnk')
