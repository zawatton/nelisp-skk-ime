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
$artifacts=Join-Path $root 'build/input-rules-results'
New-Item -ItemType Directory $artifacts -Force | Out-Null
$private=Join-Path $artifacts ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $private | Out-Null
$savedRules=$env:NELISP_IME_INPUT_RULES;$savedKeymap=$env:NELISP_TEST_KEYMAP_EXE;$savedLocal=$env:LOCALAPPDATA
$assertions=0
try {
 $env:NELISP_IME_INPUT_RULES=Join-Path $private 'input-rules.conf'
 $env:NELISP_TEST_KEYMAP_EXE=[IO.Path]::GetFullPath($KeymapExe)
 $env:LOCALAPPDATA=Join-Path $private 'localappdata'
 Copy-Item -LiteralPath (Join-Path $root 'windows/keymap/input-rules.conf') -Destination $env:NELISP_IME_INPUT_RULES
 # Exercise resident watching first, then explicit editor-style reloads.
 # Stop our resident before direct reloads so one edit has one trigger.
 $script='a i SPACE WAIT3000 ENTER CTX2 z BRACKET a BS BS APPCLEAR PAREN a BS BS BRACKET a BS BS l PAREN CTRLJ PERIOD q CURLY q IRWATCH WAIT1000 IRZEN WAIT45000 CURLY PERIOD IRSTOP IRCUSTOM IRRELOAD WAIT45000 PERIOD IROFF IRRELOAD WAIT45000 PAREN'
 $lines=@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../run-harness.ps1') `
   -Script $script -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
   -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
   -TsfHostExe (Join-Path $rulesBuild 'input-rules-host.exe') -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 240 2>&1)
 $lines | Set-Content -LiteralPath (Join-Path $artifacts 'tsf.log') -Encoding UTF8
 if($LASTEXITCODE -ne 0){throw "Input rules TSF harness exit $LASTEXITCODE"}
 $text=$lines -join "`n"
 function Require([string]$pattern,[string]$label){
   if($text -notmatch $pattern){throw "Input rules assertion: $label"};$script:assertions++
 }
 Require 'AFTER PAREN BUF=\[\(\)\] SEL=1,1 COMP=-' 'hiragana pair caret'
 Require 'AFTER a BUF=\[\(\u3042\)\] SEL=2,2 COMP=-' 'typing inside pair'
 Require 'AFTER BS BUF=\[\(\)\] SEL=1,1 COMP=-' 'Backspace content'
 Require 'AFTER BS BUF=\[\)\] SEL=0,0 COMP=-' 'DDSKK Backspace retains closer'
 Require 'AFTER BRACKET BUF=\[\u300c\u300d\)\] SEL=1,1 COMP=-' 'Japanese bracket pair'
 Require 'AFTER BRACKET BUF=\[\u300e\u300f\] SEL=1,1 COMP=-' 'normal multi-key opener pairs at composition commit'
 Require 'AFTER PAREN BUF=\[\(\u300d\)\] SEL=1,1 COMP=-' 'latin opener is not paired'
 Require 'AFTER PERIOD BUF=\[\(\. \u300d\)\] SEL=3,3 COMP=-' 'half-width period keeps space'
 Require 'INPUT_WATCH started=\d+ hooks=0 SendInput=0' 'resident watcher started privately'
 Require 'INPUT_WATCH stopped=1' 'resident stopped before direct reload checks'
 Require 'AFTER CURLY BUF=\[.*\uff5b\uff5d.*\] SEL=\d+,\d+ COMP=-' 'watcher width reload'
 Require 'AFTER PERIOD BUF=\[.*\u3002.*\] SEL=\d+,\d+ COMP=-' 'zenkaku period'
 Require 'AFTER PERIOD BUF=\[.*EDIT .*\] SEL=\d+,\d+ COMP=-' 'external custom symbol after ENGINE RELOAD'
 Require 'INPUT_RELOAD OK RELOADING' 'explicit reload acknowledged'
 # Pair-off is tested at the last opener: its next character is the older
 # closer, not a newly inserted close. Check the full final buffer in logs.
 $lastParen=@($lines | Where-Object {$_ -match '^AFTER PAREN BUF='})[-1]
 if($lastParen -notmatch 'BUF=\[\(\. \{\uff5b\u3002EDIT \(\uff5d\}\u300d\)\] SEL=12,12 COMP=-'){
   throw "Input rules pair-off final buffer: $lastParen"
 }
 $assertions++
 foreach($width in @('hankaku','zenkaku')) {
   [IO.File]::WriteAllText($env:NELISP_IME_INPUT_RULES,"width = $width`nauto-pair = yes`n",[Text.UTF8Encoding]::new($false))
   $oracle=Join-Path $artifacts "oracle-$width.txt"
   $probe=@(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot '../run-harness.ps1') `
     -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
     -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
     -TsfHostExe (Join-Path $build 'tsf-host.exe') -Script WAIT100 -ColdLoadSleepSec $ColdLoadSleepSec -RomajiProbePath $oracle 2>&1)
   $probe | Set-Content -LiteralPath (Join-Path $artifacts "parity-$width.log") -Encoding UTF8
   if($LASTEXITCODE -ne 0){throw "Oracle harness failed for $width"}
   & (Join-Path $rulesBuild 'input-rules-probe.exe') $oracle
   if($LASTEXITCODE -ne 0){throw "Matcher parity failed for $width"}
   $assertions++
 }
 Write-Output "PASS input rules assertions=$assertions widths=2 hooks=0 SendInput=0"
} finally {
 $env:NELISP_IME_INPUT_RULES=$savedRules;$env:NELISP_TEST_KEYMAP_EXE=$savedKeymap;$env:LOCALAPPDATA=$savedLocal
 # Leave the private fixtures under build for inspection; the harness owns
 # process cleanup, and its input-rules resident stops in the host destructor.
}
