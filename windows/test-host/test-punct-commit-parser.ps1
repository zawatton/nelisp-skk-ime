# Offline regression for RESULT snapshot assertions; never starts the harness.
$ErrorActionPreference='Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile(
 (Join-Path $PSScriptRoot 'test-punct-commit.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw "Punctuation runner parse errors: $errors" }
foreach ($name in @('Read-PunctSnapshot','Assert-PunctComposition')) {
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
