[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$BuildDirectory,
 [Parameter(Mandatory)][string]$RulesBuildDirectory,
 [Parameter(Mandatory)][string]$KeymapExe,
 [Parameter(Mandatory)][string]$EngineExecutablePath,
 [int]$ColdLoadSleepSec=45
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=[IO.Path]::GetFullPath($BuildDirectory)
$rulesBuild=[IO.Path]::GetFullPath($RulesBuildDirectory)
$artifacts=Join-Path $root 'build/input-rules-reload-results'
New-Item -ItemType Directory $artifacts -Force | Out-Null
$savedRules=$env:NELISP_IME_INPUT_RULES
$savedKeymap=$env:NELISP_TEST_KEYMAP_EXE
$savedLocal=$env:LOCALAPPDATA
$savedConversion=$env:DDSKK_HARNESS_LOCAL_CONVERSION
$savedDiagnostics=$env:DDSKK_HARNESS_DIAGNOSTICS
$assertions=0
try {
 $env:NELISP_TEST_KEYMAP_EXE=[IO.Path]::GetFullPath($KeymapExe)
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 foreach($local in @(0,1)) {
  $private=Join-Path $artifacts ([guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $private | Out-Null
  $env:NELISP_IME_INPUT_RULES=Join-Path $private 'input-rules.conf'
  $env:LOCALAPPDATA=Join-Path $private 'localappdata'
  $env:DDSKK_HARNESS_LOCAL_CONVERSION=[string]$local
  Copy-Item -LiteralPath (Join-Path $root 'windows/keymap/input-rules.conf') -Destination $env:NELISP_IME_INPUT_RULES
  # One app/context stays open across watcher and explicit reloads. Warm the
  # provider, then test rule adoption without restarting or changing focus.
  $script='a i SPACE WAIT3000 ENTER APPCLEAR CURLY IRWATCH WAIT1000 IRZEN WAIT45000 CURLY PERIOD IRSTOP IRCUSTOM IRRELOAD WAIT45000 PERIOD IROFF IRRELOAD WAIT45000 CURLY'
  $lines=@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../run-harness.ps1') `
    -Script $script -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
    -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
    -TsfHostExe (Join-Path $rulesBuild 'input-rules-host.exe') -LocalConversion $local `
    -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 240 2>&1)
  $lines | Set-Content -LiteralPath (Join-Path $artifacts "local-$local.log") -Encoding UTF8
  if($LASTEXITCODE -ne 0){throw "Rules reload harness local=$local exit=$LASTEXITCODE"}
  $checkpoints=@($lines | Where-Object {$_ -match '^AFTER (CURLY|PERIOD) BUF='})
  $open=[char]0xff5b;$close=[char]0xff5d;$period=[char]0x3002
  $expected=@(
   'AFTER CURLY BUF=[{}] SEL=1,1 COMP=-',
   "AFTER CURLY BUF=[{${open}${close}}] SEL=2,2 COMP=-",
   "AFTER PERIOD BUF=[{${open}${period}${close}}] SEL=3,3 COMP=-",
   "AFTER PERIOD BUF=[{${open}${period}EDIT ${close}}] SEL=8,8 COMP=-",
   "AFTER CURLY BUF=[{${open}${period}EDIT ${open}${close}}] SEL=9,9 COMP=-"
  )
  if($checkpoints.Count -ne $expected.Count){throw "Rules reload checkpoint count local=$local actual=$($checkpoints.Count) expected=$($expected.Count)"}
  for($i=0;$i -lt $expected.Count;$i++) {
   if($checkpoints[$i] -cne $expected[$i]){throw "Rules reload local=$local checkpoint=$i expected=$($expected[$i]) actual=$($checkpoints[$i])"}
   $assertions++
  }
  if(($lines -join "`n") -notmatch 'INPUT_WATCH stopped=1'){throw "Rules reload resident cleanup local=$local"}
  $assertions++
 }
 Write-Output "PASS input rules reload assertions=$assertions paths=2 hooks=0 SendInput=0"
} finally {
 $env:NELISP_IME_INPUT_RULES=$savedRules
 $env:NELISP_TEST_KEYMAP_EXE=$savedKeymap
 $env:LOCALAPPDATA=$savedLocal
 $env:DDSKK_HARNESS_LOCAL_CONVERSION=$savedConversion
 $env:DDSKK_HARNESS_DIAGNOSTICS=$savedDiagnostics
}
