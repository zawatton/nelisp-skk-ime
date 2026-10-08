param([Parameter(Mandatory)][string]$LogPath)
$ErrorActionPreference = 'Stop'
# Exercise the production parser without starting a host or writing registry keys.
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $PSScriptRoot 'test-registration-nested.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw $errors }
$definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Checkpoint'}, $true)
Invoke-Expression $definition.Extent.Text
$text = [IO.File]::ReadAllText((Resolve-Path $LogPath), [Text.Encoding]::UTF8)
foreach ($label in @('END','REINSERT')) {
  $checkpoint = Checkpoint $text $label
  if ($checkpoint[0] -ne 'て愛' -or $checkpoint[1] -ne '-') { throw "Wrong $label checkpoint: $checkpoint" }
}
$learn = Checkpoint $text 'LEARN'
if ($learn[0] -ne '▼て愛' -or $learn[1] -ne '0,3') { throw "Wrong learning checkpoint: $learn" }
foreach ($broken in @('', "AFTER END BUF=[て愛] SEL=0 COMP=-`nAFTER END BUF=[て愛] SEL=0 COMP=-")) {
  $rejected = $false
  try { Checkpoint $broken 'END' | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw 'Parser accepted missing/duplicate checkpoint' }
}
Write-Output 'PASS registration checkpoint parser: 3 real checkpoints, 2 negative controls'
