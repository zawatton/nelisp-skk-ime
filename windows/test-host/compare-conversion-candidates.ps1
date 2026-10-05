param([Parameter(Mandatory)][string]$Baseline,[Parameter(Mandatory)][string]$Candidate)
$ErrorActionPreference='Stop'
$a=Get-Content $Baseline -Raw | ConvertFrom-Json
$b=Get-Content $Candidate -Raw | ConvertFrom-Json
if ($a.samples.Count -ne $b.samples.Count) { throw 'Sample count differs' }
if ($a.samples.Count -eq 0) { throw 'No candidate samples' }
for ($i=0; $i -lt $a.samples.Count; $i++) {
  $x=$a.samples[$i]; $y=$b.samples[$i]
  if ($x.name -ne $y.name -or $x.kind -ne $y.kind -or $x.response -cne $y.response) {
    throw "Candidate/state mismatch at sample $i ($($x.name))"
  }
}
Write-Output "PASS candidate/state equality: $($a.samples.Count)/$($a.samples.Count)"
if ($a.PSObject.Properties.Name -contains 'learning') {
  if ($a.learning.Count -ne $b.learning.Count) { throw 'Learning sample count differs' }
  for ($i=0; $i -lt $a.learning.Count; $i++) {
    foreach ($field in @('name','first','selected','learned')) {
      if ($a.learning[$i].$field -cne $b.learning[$i].$field) { throw "Learning mismatch at $i/$field" }
    }
  }
  if ($a.learning.Count) {
    Write-Output "PASS learned candidate/state equality: $($a.learning.Count)/$($a.learning.Count)"
  } else { Write-Output 'Learning not measured (0 samples)' }
}
