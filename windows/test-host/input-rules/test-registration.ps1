[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$BuildDirectory,
 [Parameter(Mandatory)][string]$RulesBuildDirectory,
 [Parameter(Mandatory)][string]$EngineExecutablePath,
 [int]$ColdLoadSleepSec=45
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=[IO.Path]::GetFullPath($BuildDirectory)
$rulesBuild=[IO.Path]::GetFullPath($RulesBuildDirectory)
$artifacts=Join-Path $root 'build/round3-registration'
New-Item -ItemType Directory $artifacts -Force | Out-Null
$oldRules=$env:NELISP_IME_INPUT_RULES
$oldDiagnostics=$env:DDSKK_HARNESS_DIAGNOSTICS
try {
 # A missing private file exercises production defaults, including pairing.
 $env:NELISP_IME_INPUT_RULES=Join-Path $artifacts ([guid]::NewGuid().ToString('N')+'.conf')
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 # Different readings ensure both contexts enter registration rather than
 # reusing the word learned in the first context. Keep the second closer.
 $keys='P a p a p a SPACE SETTLE30000 t e s u t o ENTER SETTLE30000 CTX2 PAREN P a p a p i SPACE SETTLE30000 t e s u t o ENTER SETTLE30000'
 $lines=@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../run-harness.ps1') `
  -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
  -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
  -TsfHostExe (Join-Path $rulesBuild 'input-rules-host.exe') -Script $keys -ColdLoadSleepSec $ColdLoadSleepSec 2>&1)
 $lines | Set-Content (Join-Path $artifacts 'registration.log') -Encoding UTF8
 if($LASTEXITCODE){throw "Registration harness exit $LASTEXITCODE"}
 $text=$lines -join "`n"
 $checks=@(
  'AFTER SETTLE30000 BUF=\[\u3066\u3059\u3068\] SEL=3,3 COMP=-',
  'AFTER PAREN BUF=\[\(\)\] SEL=1,1 COMP=-',
  'AFTER SETTLE30000 BUF=\[\(\u3066\u3059\u3068\)\] SEL=4,4 COMP=-'
 )
 foreach($pattern in $checks){if($text -notmatch $pattern){throw "Registration mismatch: $pattern"}}
 if($text -match '\u3066\u3059\u3068\u3066\u3059\u3068'){throw 'Registration duplicated text'}
 if(@($lines | Where-Object {$_ -match 'raw=STATE registration '}).Count -lt 2){throw 'Both readings must enter registration'}
 Write-Output 'PASS registration default-pair-on assertions=5 contexts=2 SendInput=0'
} finally {
 $env:NELISP_IME_INPUT_RULES=$oldRules
 $env:DDSKK_HARNESS_DIAGNOSTICS=$oldDiagnostics
}
