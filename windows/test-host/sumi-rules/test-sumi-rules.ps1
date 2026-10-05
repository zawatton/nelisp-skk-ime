[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$BuildDirectory,
 [Parameter(Mandatory)][string]$RulesBuildDirectory,
 [Parameter(Mandatory)][string]$KeymapExe,
 [Parameter(Mandatory)][string]$IndicatorExe,
 [Parameter(Mandatory)][string]$EngineExecutablePath,
 [int]$ColdLoadSleepSec=45
)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build=[IO.Path]::GetFullPath($BuildDirectory)
$rulesBuild=[IO.Path]::GetFullPath($RulesBuildDirectory)
$artifacts=Join-Path $root 'build/validation/sumi-settings'
$private=Join-Path $artifacts ('sn3-e2e-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $private -Force | Out-Null
$saved=@{}
foreach($n in @('NELISP_IME_INPUT_RULES','NELISP_TEST_KEYMAP_EXE','NELISP_TEST_SUMI_EXE','LOCALAPPDATA')){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
try {
 $env:NELISP_IME_INPUT_RULES=Join-Path $private 'input-rules.conf'
 $env:NELISP_TEST_KEYMAP_EXE=[IO.Path]::GetFullPath($KeymapExe)
 $env:NELISP_TEST_SUMI_EXE=[IO.Path]::GetFullPath($IndicatorExe)
 $env:LOCALAPPDATA=Join-Path $private 'localappdata'
 Copy-Item -LiteralPath (Join-Path $root 'sumi-ui/templates/input-rules.conf') -Destination $env:NELISP_IME_INPUT_RULES
 $lines=@(& pwsh -NoProfile -File (Join-Path $PSScriptRoot '../run-harness.ps1') `
  -Script 'a i SPACE WAIT3000 ENTER CTX2 PERIOD IRWATCH WAIT1000 SUMIEDIT WAIT45000 PERIOD IRSTOP' `
  -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
  -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
  -TsfHostExe (Join-Path $rulesBuild 'fixture/Release/input-rules-host.exe') `
  -ArtifactDirectory $private -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 150 2>&1)
 $exit=$LASTEXITCODE
 $lines | Set-Content -LiteralPath (Join-Path $artifacts 'sn3-e2e.log') -Encoding utf8
 $text=$lines -join "`n"
 if($exit -ne 0){throw "Sumi rules harness exit $exit"}
 $patterns=@('AFTER PERIOD BUF=\[\. \]','INPUT_WATCH started=\d+ hooks=0 SendInput=0',
 'SUMI_EDITOR gtk-edit-and-save=1 explicit-reload=0','AFTER PERIOD BUF=\[\. SUMI \]', 'INPUT_WATCH stopped=1')
 foreach($p in $patterns){if($text -notmatch $p){throw "Missing E2E assertion: $p"};Write-Output "PASS $p"}
 Write-Output "PASS sumi-rules-e2e assertions=5 watcher=real engine=real explicit-reload=0"
} finally {foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n])}}
