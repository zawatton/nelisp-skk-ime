param([Parameter(Mandatory)][string]$Trace)
$ErrorActionPreference='Stop'
$stack=[Collections.Generic.List[string]]::new()
$times=@{}; $active=$false; $requests=0
foreach ($line in Get-Content $Trace) {
  if ($line -match '^dispatch tick=.*request=SESSION bench CONTROL CONVERT-KEYS ') {
    $active=$true; $stack.Clear(); $requests++
  }
  if (-not $active) { continue }
  if ($line -match '^engine-phase name=.* ms=(\d+) next=(.+)$') {
    $ms=[int]$Matches[1]; $next=$Matches[2]
    foreach ($name in $stack) { $times[$name].inclusive += $ms }
    if ($stack.Count) { $times[$stack[$stack.Count-1]].self += $ms }
    if ($next.StartsWith('enter:')) {
      $name=$next.Substring(6)
      if (-not $times.ContainsKey($name)) { $times[$name]=@{inclusive=0; self=0; calls=0} }
      $times[$name].calls++; $stack.Add($name)
    } elseif ($next.StartsWith('leave:')) {
      $name=$next.Substring(6)
      if (-not $stack.Count -or $stack[$stack.Count-1] -ne $name) { throw "Unbalanced profile: $next" }
      $stack.RemoveAt($stack.Count-1)
    }
  }
  if ($line -match '^dispatch done ') { $active=$false }
}
if (-not $requests -or -not $times.Count) { throw 'No profiled conversion requests' }
Write-Output "Profile requests=$requests functions=$($times.Count); host timestamp resolution about 16 ms; tracing overhead included"
$times.Keys | ForEach-Object {
  [pscustomobject]@{function=$_; calls=$times[$_].calls; inclusiveMs=$times[$_].inclusive; selfMs=$times[$_].self}
} | Sort-Object selfMs -Descending | Format-Table -AutoSize
