param(
  [switch]$Unregister,
  [string]$DllPath = ''
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ($DllPath) {
  $dll = [IO.Path]::GetFullPath($DllPath)
} else {
  $dll = Join-Path $repo 'build\windows\Debug\ddskk-ime.dll'
}
if (-not (Test-Path -LiteralPath $dll)) {
  throw "Build the Debug DLL first: $dll"
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
  if ($Unregister) { $arguments += '-Unregister' }
  if ($DllPath) { $arguments += @('-DllPath', $dll) }
  Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $arguments
  exit
}

$regsvr = Join-Path $env:SystemRoot 'System32\regsvr32.exe'
$arguments = @('/s')
if ($Unregister) { $arguments += '/u' }
$arguments += $dll
$process = Start-Process $regsvr -ArgumentList $arguments -Wait -PassThru
if ($process.ExitCode -ne 0) {
  throw "regsvr32 failed with exit code $($process.ExitCode)"
}
$operation = if ($Unregister) { 'unregistered' } else { 'registered' }
Write-Host "NeLisp IME ${operation}: $dll"
