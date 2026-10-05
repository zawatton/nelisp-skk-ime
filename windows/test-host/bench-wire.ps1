[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$Output='build/w/round2-wire-micro.json',
      [string]$Script='engine/bench-wire.el',
      [string[]]$Cases=@('legacy-reply','cached-reply','utf8-reply','decimal-request','utf8-request'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out=[IO.Path]::GetFullPath((Join-Path $root $Output))
$private=Join-Path ([IO.Path]::GetDirectoryName($out)) ('wire-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $private -Force)
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=$Runtime
$info.Arguments='--load "'+(Join-Path $root $Script)+'"'
$info.WorkingDirectory=$root; $info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
$info.EnvironmentVariables['DDSKK_BENCH_ROOT']=$root
$info.EnvironmentVariables['DDSKK_USER_JISYO']=Join-Path $private 'user-jisyo'
$info.EnvironmentVariables['LOCALAPPDATA']=$private
$process=[Diagnostics.Process]::new(); $process.StartInfo=$info
$rows=[Collections.Generic.List[object]]::new()
function Machine-Load {
  $timer=[Diagnostics.Stopwatch]::StartNew(); $before=@{}
  Get-Process | ForEach-Object {try {$before[$_.Id]=$_.CPU} catch {}}
  Start-Sleep -Seconds 1
  $top=@(Get-Process | ForEach-Object {if($before.ContainsKey($_.Id)){try {
    [pscustomobject]@{pid=$_.Id; name=$_.ProcessName; cpuMs=1000*($_.CPU-$before[$_.Id])}
  } catch {}}} | Sort-Object cpuMs -Descending | Select-Object -First 8)
  [pscustomobject]@{utc=[DateTime]::UtcNow.ToString('o'); intervalMs=$timer.Elapsed.TotalMilliseconds; top=$top}
}
$load=Machine-Load
try {
  [void]$process.Start()
  $errorRead=$process.StandardError.ReadToEndAsync()
  foreach ($kind in $Cases) {
    $ready=$process.StandardOutput.ReadLine()
    if ($ready -ne "READY $kind") {throw "Unexpected microbenchmark marker: $ready"}
    $process.Refresh(); $before=$process.TotalProcessorTime.TotalMilliseconds
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $process.StandardInput.WriteLine('x'); $process.StandardInput.Flush()
    $done=$process.StandardOutput.ReadLine(); $timer.Stop(); $process.Refresh()
    if ($done -ne "DONE $kind") {throw "Unexpected microbenchmark marker: $done"}
    $rows.Add([pscustomobject]@{kind=$kind; iterations=100; cpuMs=$process.TotalProcessorTime.TotalMilliseconds-$before;
      wallMs=$timer.Elapsed.TotalMilliseconds})
  }
  [pscustomobject]@{runtimeHash=(Get-FileHash $Runtime).Hash; samples=@($rows); load=$load;
    utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $out
  $rows | Format-Table
} finally {
  if ($process.Id -and -not $process.HasExited) {$process.Kill(); $process.WaitForExit()}
  if ($errorRead) {$errorRead.Result | Set-Content -Encoding UTF8 (Join-Path $private 'stderr.log')}
  $process.Dispose()
}
