param(
  [Parameter(Mandatory=$true)][string]$Executable,
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$ExecutableArguments
)
$ErrorActionPreference = 'Stop'
$id = [guid]::NewGuid().ToString('N')
$key = "Software\NativeIME-test-$id"
$path = "HKCU:\$key"
$data = Join-Path ([IO.Path]::GetDirectoryName($Executable)) "test-$id"
New-Item -ItemType Directory -Path $data -Force | Out-Null
try {
  New-Item -Path $path -Force | Out-Null
  New-ItemProperty -Path $path -Name Engine -Value ddskk -PropertyType String | Out-Null
  New-ItemProperty -Path $path -Name SkkServEnable -Value 0 -PropertyType DWord | Out-Null
  $env:NATIVEIME_REGISTRY_KEY = $key
  $env:DDSKK_PIPE_NAME = "\\.\pipe\nativeime-test-$id"
  $env:DDSKK_USER_JISYO = Join-Path $data 'user.jisyo'
  $env:LOCALAPPDATA = $data
  $env:DDSKK_SKKSERV_ENABLE = '0'
  Remove-Item Env:NELISP_IME_ENGINE -ErrorAction SilentlyContinue
  & $Executable @ExecutableArguments
  $result = $LASTEXITCODE
} finally {
  Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
}
exit $result
