# Offline regression for RESULT snapshot assertions; never starts the harness.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
 (Join-Path $PSScriptRoot 'test-punct-commit.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw "Punctuation runner parse errors: $errors" }
foreach ($name in @('Read-PunctSnapshot','Assert-PunctComposition','Assert-PunctImm')) {
 $definition=$ast.Find({param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
 },$true)
 if (!$definition) { throw "Missing runner function: $name" }
 . ([scriptblock]::Create($definition.Extent.Text))
}
$checks=0
function Reject([scriptblock]$Check,[string]$Name) {
 $rejected=$false
 try { & $Check } catch { $rejected=$true }
 if (!$rejected) { throw "Broken snapshot accepted: $Name" }
 $script:checks++
}
# A valid active RESULT followed by shutdown must stay active in the assertion.
$active="COMPOSITION UPDATE range=0,4`nAFTER RESULT BUF=[ABCD] SEL=4,4 COMP=0,4`nFINAL BUF_LEN=4`nCOMPOSITION END range=0,4`n"
$snapshot=Read-PunctSnapshot $active RESULT
Assert-PunctComposition $snapshot $true 'active-before-teardown'
if ($snapshot.Hex -ne '0041004200430044') { throw 'Snapshot buffer mismatch' }
$checks++
$terminal=$active.Replace('COMP=0,4','COMP=-')
Assert-PunctComposition (Read-PunctSnapshot $terminal RESULT) $false 'committed'
$checks++
Reject { Assert-PunctComposition (Read-PunctSnapshot $terminal RESULT) $true 'ended-preedit' } 'ended-preedit'
Reject { Assert-PunctComposition $snapshot $false 'uncommitted' } 'uncommitted'
Reject { Assert-PunctComposition (Read-PunctSnapshot ($active.Replace('COMP=0,4','COMP=0,3')) RESULT) $true 'wrong-range' } 'wrong-range'
Reject { Read-PunctSnapshot "COMPOSITION END range=0,4`n" RESULT } 'missing-result'
Write-Output "PASS punctuation snapshot checks=$checks negative-controls=4"
$imm="IMMRESULT count=1 lock=10 range=0,2 hex=4eee540d`nIMMRESULT count=2 lock=12 range=2,3 hex=3002`nIMM AFTER RESULT COUNT=2 LAST=3002 TEXT=4eee540d3002`n"
Assert-PunctImm $imm 'separate-results' '4eee540d' '3002' 2
$checks++
$warmup="IMMRESULT count=1 lock=1 range=0,1 hex=3042`nIMMRESULT count=2 lock=2 range=1,2 hex=3044`nIMM AFTER APPCLEAR COUNT=0 LAST=- TEXT=-`n"
Assert-PunctImm ($warmup+$imm.Replace('lock=12','lock=11')) 'warmup-reset' '4eee540d' '3002' 2
$checks++
Reject { Assert-PunctImm ($imm.Replace('COUNT=2 LAST=3002','COUNT=1 LAST=4eee540d3002')) 'merged' '4eee540d' '3002' 2 } 'merged-results'
Reject { Assert-PunctImm ($imm.Replace('TEXT=4eee540d3002','TEXT=3002')) 'lost-word' '4eee540d' '3002' 2 } 'lost-word'
Reject { Assert-PunctImm ($imm.Replace('COUNT=2','COUNT=3')) 'duplicate' '4eee540d' '3002' 2 } 'duplicate-result'
Reject { Assert-PunctImm 'IMM AFTER RESULT COUNT=2 LAST=3002 TEXT=4eee540d3002' 'no-events' '4eee540d' '3002' 2 } 'missing-candidate-event'
Reject { Assert-PunctImm ($imm.Replace('lock=12','lock=10')) 'same-lock' '4eee540d' '3002' 2 } 'same-lock'
Reject { Assert-PunctImm ($warmup+$imm.Replace('lock=12','lock=10')) 'warmup-same-lock' '4eee540d' '3002' 2 } 'warmup-same-lock'
Write-Output "PASS punctuation snapshot/IMM checks=$checks negative-controls=10"
