[CmdletBinding()]
param([Parameter(Mandatory)][string]$LogPath)
$ErrorActionPreference = 'Stop'
# Audit the original suite's assertions against its completed harness output.
# This does not run or replace the gate, which retains its first-failure exit.
$source = Get-Content (Join-Path $PSScriptRoot 'test-ddskk-behavior.ps1') -Raw
$begin = $source.IndexOf('# Keep regex literals ASCII-only:')
$end = $source.LastIndexOf('[pscustomobject]@{')
if ($begin -lt 0 -or $end -le $begin) { throw 'Suite assertion section not found' }
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput(
    $source.Substring($begin, $end - $begin), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Suite assertion section did not parse' }
$lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
$script:behaviorText = $lines -join "`n"
$results = [Collections.Generic.List[object]]::new()
function Require([string]$pattern, [string]$label) {
  $results.Add([pscustomobject]@{Label=$label; Passed=($script:behaviorText -match $pattern)})
}
foreach ($statement in $ast.EndBlock.Statements) {
  if ($statement -is [Management.Automation.Language.IfStatementAst]) {
    # The suite's two explicit negative assertions: duplicated registration
    # and Ctrl+G timing. Evaluate the same conditions without stopping audit.
    if ($statement.Clauses.Count -ne 1 -or $statement.ElseClause) {
      throw 'Unsupported assertion structure'
    }
    $failed = . ([scriptblock]::Create($statement.Clauses[0].Item1.Extent.Text))
    $throwNode = $statement.Clauses[0].Item2.Statements[0]
    if ($throwNode -isnot [Management.Automation.Language.ThrowStatementAst]) {
      throw 'Expected original assertion throw'
    }
    $label = . ([scriptblock]::Create($throwNode.Pipeline.Extent.Text))
    $label = $label -replace '^DDSKK behavior failed: ', ''
    $results.Add([pscustomobject]@{Label=$label; Passed=(-not $failed)})
  } else {
    . ([scriptblock]::Create($statement.Extent.Text))
  }
}
foreach ($result in $results) {
  '{0}: {1}' -f $(if ($result.Passed) {'PASS'} else {'FAIL'}), $result.Label
}
$passed = @($results | Where-Object Passed).Count
'AUDIT passed={0} failed={1} actual_assertions={2} suite_declared_assertions=45' -f $passed, ($results.Count-$passed), $results.Count
if ($passed -ne $results.Count) { exit 1 }
