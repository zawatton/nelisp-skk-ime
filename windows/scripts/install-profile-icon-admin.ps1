[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$sourceDll = Join-Path $PSScriptRoot '..\build\Release\ddskk-ime.dll'
$sourceDll = [System.IO.Path]::GetFullPath($sourceDll)
if (-not (Test-Path -LiteralPath $sourceDll)) {
  throw "NeLisp IME DLL with embedded profile icon not found: $sourceDll"
}

# A machine-wide TSF profile must not point into one user's LocalAppData.
# Install the icon beside other machine-wide application data instead.
$iconDirectory = Join-Path $env:ProgramData 'DDSKK'
$iconPath = Join-Path $iconDirectory 'ddskk-ime-icons.dll'
New-Item -ItemType Directory -Path $iconDirectory -Force | Out-Null
Copy-Item -LiteralPath $sourceDll -Destination $iconPath -Force

$profilePath = 'HKLM:\Software\Microsoft\CTF\TIP\{80B44B14-B866-4EF4-A394-4FF1D87D5185}\LanguageProfile\0x00000411\{EE0012D5-8306-4388-B071-5C3C3E38F7CE}'
if (-not (Test-Path -LiteralPath $profilePath)) {
  throw "NeLisp IME machine profile not found: $profilePath"
}

New-ItemProperty -LiteralPath $profilePath -Name Description -Value 'NeLisp IME' `
  -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $profilePath -Name IconFile -Value $iconPath `
  -PropertyType String -Force | Out-Null
New-ItemProperty -LiteralPath $profilePath -Name IconIndex -Value 0 `
  -PropertyType DWord -Force | Out-Null
New-ItemProperty -LiteralPath $profilePath -Name Enable -Value 1 `
  -PropertyType DWord -Force | Out-Null
