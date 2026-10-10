[CmdletBinding()]
param([string]$Runner=(Join-Path $PSScriptRoot 'run-engine-host-s6.ps1'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($Runner),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
function StageBody([string]$name) {
  foreach($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst]},$true)) {
    foreach($clause in $node.Clauses) {
      if($clause.Item1.Extent.Text -eq ('$Stage -eq '+"'$name'")){return $clause.Item2.Extent.Text}
    }
  }
  throw "Missing stage $name"
}
$qualification=StageBody 'Qualification'
if($qualification -match 'host-windows-s6.py'){throw 'Policy IPC budget appears in Qualification'}
if($qualification -match 'INCOMPLETE S6 OS1|run-engine-host-s4.ps1'){throw 'Obsolete/unrelated Qualification gate'}
$resources=StageBody 'Resources'
if($resources -notmatch 'host-windows-s6.py' -or $resources -notmatch "'--samples','3'"){
  throw 'Three-launch policy resource gate is missing'
}
$baseline=StageBody 'NativeBaseline'
if($baseline -match 'run-engine-host-s[34].ps1|host-policy-s4.py'){throw 'Baseline forces policy ON through an aggregate'}
if($ast.Extent.Text -notmatch '\$policyEnabled=\$Stage -in @\(''Resources'',''Production''\)'){
  throw 'Native baseline/Qualification policy OFF selection changed'
}
$function=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'AssertOs1Coverage'},$true))
if($function.Count -ne 1){throw 'Missing component coverage assertion'}
# Define just the pure coverage function, never execute the runner body.
Invoke-Expression $function[0].Extent.Text
$design=[IO.File]::ReadAllText((Join-Path $root 'docs/design/engine-host-nelisp.org'))
$table=[regex]::Match($design,'(?m)^\| OS1 component \|[^\r\n]*\r?\n(?:\|[^\r\n]*(?:\r?\n|$))+').Value
$rows=@(($table.TrimEnd() -split '\r?\n') | Select-Object -Skip 2)
$gateNames=@($rows | ForEach-Object {$_.Split('|')[3].Trim() -split ',\s*'} | Select-Object -Unique)
$good=@($gateNames | ForEach-Object {@{name=$_;status='PASS'}})
$ValidateParametersOnly=$false;$results=$good;$coverage=@()
AssertOs1Coverage -DesignText $design
if($coverage.Count -ne 7 -or @($coverage | Where-Object {-not $_.executed}).Count){throw 'Incomplete positive coverage'}
function Reject([string]$label,[string]$text,[object[]]$receipts) {
  $script:results=$receipts;$script:coverage=@()
  $rejected=$false
  try{AssertOs1Coverage -DesignText $text}catch{$rejected=$true}
  if(-not $rejected){throw "False green: $label"}
}
Reject 'empty component mapping' ($design.Replace('| os1-pipe, test-private-pipe-soak |','| |')) $good
Reject 'missing gate receipt' $design @($good | Where-Object {$_.name -ne 'os1-pipe'})
$failed=@($good | ForEach-Object {@{name=$_.name;status=$(if($_.name -eq 'os1-unicode'){'FAIL'}else{'PASS'})}})
Reject 'failed gate receipt' $design $failed
Reject 'unlisted eighth component' ($design.Replace($rows[-1],$rows[-1]+"`n| Extra component | Retain native | | none |")) $good
$ValidateParametersOnly=$true;$results=@($gateNames | ForEach-Object {@{name=$_;status='parameter audit only'}});$coverage=@()
AssertOs1Coverage -DesignText $design
if($coverage.Count -ne 7 -or @($coverage | Where-Object {$_.executed}).Count){throw 'Audit claimed execution'}
Write-Output 'PASS S6 static wiring components=7 coverage_controls=4 audits_not_execution=1 stacks=0'
