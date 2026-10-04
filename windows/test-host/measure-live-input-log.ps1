[CmdletBinding()]
param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
$lines = Get-Content -LiteralPath $Path -Encoding UTF8
function Distribution([string]$name, $values) {
  $sorted = @($values | Sort-Object)
  if ($sorted.Count -eq 0) { return "$name count=0" }
  $median = if ($sorted.Count % 2) { $sorted[[int][Math]::Floor($sorted.Count / 2)] } else {
    ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2.0
  }
  $p90 = $sorted[[int][Math]::Ceiling($sorted.Count * 0.9) - 1]
  return "$name count=$($sorted.Count) median_ms=$median p90_ms=$p90 min_ms=$($sorted[0]) max_ms=$($sorted[-1])"
}
$candidate = @($lines | ForEach-Object {
  if ($_ -match '^SPACE-CANDIDATE ms=(\d+) seq=(\d+)' -and [int]$Matches[2] -gt 1) {
    [int]$Matches[1]
  }
})
Distribution 'TSF-space-to-candidate-warm' $candidate
$failed = @($lines | Where-Object { $_ -match '^PROVIDER done .*state=0' })
"provider_failed_or_timed_out=$($failed.Count) (includes first warm-up)"
$space = @($lines | ForEach-Object {
  if ($_ -match '^KEYLAT token=SPACE .*total_us=(\d+)') { [double]$Matches[1] / 1000 }
})
Distribution 'DLL-Space-key-return' $space
$phases = @{}
$hostRoundtrip = [Collections.Generic.List[int]]::new()
$cpu = [Collections.Generic.List[int]]::new()
$dictionary = [Collections.Generic.List[int]]::new()
$converting = $false
foreach ($line in $lines) {
  if ($line -match '^dispatch .*request=.*CONTROL CONVERT-KEYS') { $converting = $true }
  elseif ($line -match '^dispatch .*request=') { $converting = $false }
  if (-not $converting) { continue }
  if ($line -match '^engine-phase name=(\S+) ms=(\d+)') {
    $name = $Matches[1]
    if (-not $phases.ContainsKey($name)) { $phases[$name] = [Collections.Generic.List[int]]::new() }
    $phases[$name].Add([int]$Matches[2])
  }
  if ($line -match '^dictionary-relay ms=(\d+)') { $dictionary.Add([int]$Matches[1]) }
  if ($line -match '^dispatch done .*ms=(\d+) cpu_ms=(\d+)') {
    $hostRoundtrip.Add([int]$Matches[1]); $cpu.Add([int]$Matches[2]); $converting = $false
  }
}
Distribution 'Host-engine-roundtrip' $hostRoundtrip
Distribution 'Runtime-process-CPU' $cpu
Distribution 'Dictionary-host-relay' $dictionary
foreach ($name in @($phases.Keys | Sort-Object)) { Distribution "Engine-$name" $phases[$name] }
if ($candidate.Count -lt 20) { throw "Only $($candidate.Count) completed warm TSF conversions; need >=20" }
