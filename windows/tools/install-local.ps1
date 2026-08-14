param(
  [Parameter(Mandatory = $true)]
  [string]$EngineExecutable,
  [string]$BuildDirectory = '',
  [switch]$SkipRegistration
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildDirectory) {
  $BuildDirectory = Join-Path $repo 'build\windows\Debug'
}
$build = (Resolve-Path -LiteralPath $BuildDirectory).Path
$engine = (Resolve-Path -LiteralPath $EngineExecutable).Path
$required = @('ddskk-ime.dll', 'ddskk-engine-host.exe', 'ddskk-ime-config.exe')
foreach ($name in $required) {
  $path = Join-Path $build $name
  if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $path" }
}

$version = Get-Date -Format 'yyyyMMdd-HHmmss'
$install = Join-Path $env:LOCALAPPDATA "DDSKK\$version"
New-Item -ItemType Directory -Path $install -Force | Out-Null
foreach ($name in $required) {
  Copy-Item -LiteralPath (Join-Path $build $name) -Destination $install
}
Copy-Item -LiteralPath $engine -Destination (Join-Path $install 'nelisp-ddskk.exe')

if (-not $SkipRegistration) {
  $register = Join-Path $PSScriptRoot 'register-debug.ps1'
  & $register -DllPath (Join-Path $install 'ddskk-ime.dll')
}
Write-Host "DDSKK runtime installed: $install"
Write-Host 'The installed copy is independent of the development repository.'
