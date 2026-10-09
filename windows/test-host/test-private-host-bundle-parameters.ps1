[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'test-private-host-bundle.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Runner parse errors: $errors" }
$definition = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Assert-GateParameters'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$definition = $ast.Find({ param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Gate'
}, $true)
. ([scriptblock]::Create($definition.Extent.Text))
$ValidateParametersOnly = $true
$gates = 0
$target = Join-Path $PSScriptRoot 'test-core-hot-swap.ps1'
$baseArguments = @('-NoProfile','-File',$target,'-BuildDirectory','unused','-EngineExecutablePath','unused')
$controls = @(
  @{ Arguments=$baseArguments; Expected='missing mandatory parameter(s): RepositoryPath' },
  @{ Arguments=($baseArguments + @('-RepositoryPath','unused','-UnknownOption','unused')); Expected='unknown parameter -UnknownOption' },
  @{ Arguments=($baseArguments + @('-RepositoryPath')); Expected='missing value for -RepositoryPath' }
)
foreach ($control in $controls) {
  $message = ''
  try { Gate 'negative-control' 'pwsh' $control.Arguments }
  catch { $message = $_.Exception.Message }
  if (-not $message.Contains('FAIL negative-control parameter error:') -or
      -not $message.Contains($control.Expected)) { throw "Negative control failed: $message" }
  Write-Output $message
}
if ($gates -ne 0) { throw 'A parameter error incorrectly counted as a passing gate' }
# Audit the actual stage's argument arrays, with no files, registry or stacks.
$output = @(& pwsh -NoProfile -NonInteractive -File $runner -Stage EndToEnd -Runtime unused -ValidateParametersOnly)
if ($LASTEXITCODE -ne 0 -or ($output -join "`n") -notmatch 'parameter audit gates=15 stacks=0') {
  throw "EndToEnd parameter audit failed: $output"
}
$output | Write-Output
Write-Output 'PASS bundle parameter regression negative_controls=3 audited_gates=15 stacks=0'
