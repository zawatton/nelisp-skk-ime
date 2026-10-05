[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$BuildDirectory,
 [Parameter(Mandatory)][string]$CaretBuildDirectory,
 [Parameter(Mandatory)][string]$EngineExecutablePath,
 [int]$ColdLoadSleepSec = 45,
 [switch]$ReuseCaseLogs
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$build = [IO.Path]::GetFullPath($BuildDirectory)
$caret = [IO.Path]::GetFullPath($CaretBuildDirectory)
$artifacts = Join-Path $root 'build/auto-pair-results'
New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
$saved = @{}
foreach ($name in @('NATIVEIME_TEST_TERMINAL','NATIVEIME_TEST_CHROMIUM','NATIVEIME_TEST_QUEUED',
 'NELISP_IME_INPUT_RULES','DDSKK_HARNESS_DIAGNOSTICS')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$assertions = 0
function Require([bool]$condition, [string]$label) {
 if (!$condition) { throw "Auto-pair assertion: $label" }; $script:assertions++
}
try {
 $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
 $rules = Join-Path $artifacts 'input-rules.conf'
 $env:NELISP_IME_INPUT_RULES = $rules
 foreach ($local in @(0,1)) {
  foreach ($hostKind in @('terminal','chromium')) {
   $env:NATIVEIME_TEST_TERMINAL = if ($hostKind -eq 'terminal') { '1' } else { $null }
   $env:NATIVEIME_TEST_CHROMIUM = if ($hostKind -eq 'chromium') { '1' } else { $null }
   $env:NATIVEIME_TEST_QUEUED = $null
   # Renaming our private host exercises absent-value application defaults.
   $exe = Join-Path $caret $(if ($hostKind -eq 'terminal') { 'WindowsTerminal.exe' } else { 'msedge.exe' })
   Copy-Item -LiteralPath (Join-Path $caret 'auto-pair-host.exe') -Destination $exe -Force
   [IO.File]::WriteAllText($rules, "width = hankaku`nauto-pair = yes`n", [Text.UTF8Encoding]::new($false))
   $args = @{
    RepositoryPath=$root; DllPath=(Join-Path $build 'ddskk-ime.dll'); CoreDllPath=(Join-Path $build 'ddskk-ime-core.dll')
    EngineHostPath=(Join-Path $build 'ddskk-engine-host.exe'); EngineExecutablePath=$EngineExecutablePath
    TsfHostExe=$exe; ColdLoadSleepSec=$ColdLoadSleepSec; LocalConversion=$local; TsfHostTimeoutSec=120
   }
   if ($ReuseCaseLogs) {
    $lines = @(Get-Content (Join-Path $artifacts "$hostKind-local$local.log") -Encoding UTF8)
   } else {
    $lines = @(& (Join-Path $PSScriptRoot '../run-harness.ps1') @args -Script 'PAREN a APPCLEAR z BRACKET APPCLEAR l PAREN CTRLJ APPCLEAR FAILTEXT PAREN' 2>&1)
   }
   $lines | Set-Content (Join-Path $artifacts "$hostKind-local$local.log") -Encoding UTF8
   if (!$ReuseCaseLogs) { Require ($LASTEXITCODE -eq 0) "$hostKind local=$local harness exit" }
   $text = $lines -join "`n"
   Require ($text -match 'CARET_HOST token=PAREN shell=\(\) caret=1 left=1,1') 'pair cursor via Left'
   Require ($text -match 'CARET_HOST token=a shell=\(あ\) caret=2 left=1,1') 'next kana follows shell cursor'
   Require ($text -match 'CARET_HOST token=BRACKET shell=『』 caret=1 left=2,2') 'multi-key composition closer'
   $parenLines = @($lines | Where-Object { $_ -match '^CARET_HOST token=PAREN ' })
   Require ($parenLines.Count -eq 3) 'normal, latin, and failed-write observations'
   Require ($parenLines[1] -match 'shell= caret=0 left=2,2' -and $text -match 'TESTKEYDOWN vk=39 eaten=0') 'latin does not inject'
   Require ($parenLines[2] -match 'shell= caret=0 left=2,2') 'failed write does not commit closer or inject'
   Require (@($lines | Where-Object { $_ -match '^CARET_KEY tag=4e494b4d modifiers=0$' }).Count -eq 4) 'exact tagged neutral down/up count; failed commit adds none'
   Require ($text -notmatch 'CARET_ERROR') 'after unlock and extended arrows'
   # Pair-off is a separate effective rule export, not a test-only branch.
   [IO.File]::WriteAllText($rules, "auto-pair = no`n", [Text.UTF8Encoding]::new($false))
   if ($ReuseCaseLogs) {
    $off = @(Get-Content (Join-Path $artifacts "$hostKind-local$local-off.log") -Encoding UTF8)
   } else {
    $off = @(& (Join-Path $PSScriptRoot '../run-harness.ps1') @args -Script 'PAREN' 2>&1)
   }
   $off | Set-Content (Join-Path $artifacts "$hostKind-local$local-off.log") -Encoding UTF8
   if (!$ReuseCaseLogs) { Require ($LASTEXITCODE -eq 0) 'pair-off harness exit' }
   Require ((($off -join "`n") -match 'CARET_HOST token=PAREN shell=\( caret=1 left=0,0') -and (($off -join "`n") -notmatch 'CARET_KEY')) 'pair off no keys'
  }
 }
 # An application-owned character is already queued when the pair commits.
 $env:NATIVEIME_TEST_TERMINAL='1'; $env:NATIVEIME_TEST_CHROMIUM=$null; $env:NATIVEIME_TEST_QUEUED='1'
 [IO.File]::WriteAllText($rules, "auto-pair = yes`n[pairs-hankaku]`n`"(`" = `"(`" `"))`"`n[pairs]`n`"(`" = `"(`" `"))`"`n", [Text.UTF8Encoding]::new($false))
 $args.LocalConversion=0; $args.TsfHostExe=Join-Path $caret 'WindowsTerminal.exe'
 $queued=@(& (Join-Path $PSScriptRoot '../run-harness.ps1') @args -Script 'PAREN' 2>&1)
 $queued | Set-Content (Join-Path $artifacts 'queued-multi-closer.log') -Encoding UTF8
 Require ($LASTEXITCODE -eq 0 -and (($queued -join "`n") -match 'CARET_HOST token=PAREN shell=\(x\)\) caret=2 left=2,2')) 'two closer characters precede queued user input'
 Write-Output "PASS auto-pair harness assertions=$assertions local-conversion=0,1 hosts=terminal,chromium reused-case-logs=$ReuseCaseLogs"
} finally {
 foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
}
