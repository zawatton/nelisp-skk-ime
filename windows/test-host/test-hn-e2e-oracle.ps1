# Coordinator-only HN10b. SelfTest starts neither a stack nor Emacs.
[CmdletBinding()]
param([string]$Runtime=$env:HN_IME_RUNTIME,[string]$BuildDir='build/w',
      [string]$Emacs='emacs',[switch]$SelfTest)
$ErrorActionPreference='Stop'
$driver=Join-Path $PSScriptRoot 'test-hn-e2e-oracle.py'
if($SelfTest){
  & python -B $driver --self-test
}else{
  if(-not $Runtime){throw 'HN_IME_RUNTIME or -Runtime is required'}
  & python -B $driver --runtime $Runtime --build-dir $BuildDir --emacs $Emacs
}
if($LASTEXITCODE -ne 0){throw 'HN10b S2.3 failed; see retained exact-byte artifacts and owner/wire diagnostics'}
