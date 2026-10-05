param([Parameter(Mandatory)][string]$Baseline,[Parameter(Mandatory)][string]$Candidate)
$ErrorActionPreference='Stop'
$a=Get-Content $Baseline -Raw | ConvertFrom-Json
$b=Get-Content $Candidate -Raw | ConvertFrom-Json
foreach ($field in @('runtimeHash','dictionaryHash','corpusHash','server','serverOnly')) {
  if ($a.$field -ne $b.$field) { throw "Incomparable logs: $field differs" }
}
$failed=$false
foreach ($kind in @('plain','okuri')) {
  $x=@($a.samples | Where-Object { $_.kind -eq $kind -and -not $_.cold } | Sort-Object cpuMs)
  $y=@($b.samples | Where-Object { $_.kind -eq $kind -and -not $_.cold } | Sort-Object cpuMs)
  if ($x.Count -lt 20 -or $y.Count -ne $x.Count) { throw "Invalid sample counts for $kind" }
  $p=[int][Math]::Ceiling($x.Count*.5)-1
  if ($x[$p].cpuMs -le 0) { throw 'Zero baseline CPU median' }
  $ratio=$y[$p].cpuMs/$x[$p].cpuMs
  Write-Output ("{0} n={1} baseline={2:F3} candidate={3:F3} ratio={4:F3} limit=0.5" -f $kind,$x.Count,$x[$p].cpuMs,$y[$p].cpuMs,$ratio)
  if ($ratio -gt .5) { $failed=$true }
}
if ($failed) { throw 'FAIL S2.1: engine CPU p50 ratio exceeds 0.5' }
Write-Output 'PASS S2.1: 2/2 kinds'
