[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path $root ('build/w/parser-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=$Runtime
$start.Arguments='--load engine/bench-eg1.el'
$start.WorkingDirectory=$root
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.RedirectStandardInput=$true
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.EnvironmentVariables['DDSKK_USER_JISYO']=Join-Path $run 'user.jisyo'
$start.EnvironmentVariables['LOCALAPPDATA']=$run
$process=[Diagnostics.Process]::new(); $process.StartInfo=$start
$rows=[Collections.Generic.List[object]]::new()
try {
  [void]$process.Start()
  $errors=$process.StandardError.ReadToEndAsync()
  while ($true) {
    $pending=$process.StandardOutput.ReadLineAsync()
    if (-not $pending.Wait(120000)) {throw 'Parser benchmark timed out'}
    $line=$pending.Result
    if ($null -eq $line) {break}
    if ($line.StartsWith('READY ')) {
      $watch=[Diagnostics.Stopwatch]::StartNew()
      $process.StandardInput.WriteLine('GO'); $process.StandardInput.Flush()
      $pending=$process.StandardOutput.ReadLineAsync()
      if (-not $pending.Wait(30000)) {throw 'Parser sample timed out'}
      $watch.Stop(); $done=$pending.Result
      if (-not $done.StartsWith('DONE ')) {throw "Unexpected sample: $done"}
      $rows.Add([pscustomobject]@{sample=$line; n=100; wallMs=$watch.Elapsed.TotalMilliseconds; engine=$done})
      Write-Output "$line n=100 wall_ms=$($watch.Elapsed.TotalMilliseconds) $done"
    }
  }
  if (-not $process.WaitForExit(5000)) {throw 'Parser process failed to exit'}
  if ($process.ExitCode -ne 0) {throw "Parser exit $($process.ExitCode): $($errors.Result)"}
  $rows.ToArray() | ConvertTo-Json | Set-Content -Encoding UTF8 $Output
} finally {
  if ($process.Id -and -not $process.HasExited) {$process.Kill(); [void]$process.WaitForExit(5000)}
  $process.Dispose()
}
