[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path (Join-Path $root $BuildDir) ('hygiene-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$utf8=[Text.UTF8Encoding]::new($false)
$jisyo=Join-Path $run 'user.jisyo'
[IO.File]::WriteAllText($jisyo,"crtest /Alpha/Beta/`r/`r`ncrtestk /`r/Gamma/`r`n",$utf8)
[IO.File]::WriteAllText($jisyo+'.journal',"journaltest /`r/Delta/`r`n",$utf8)
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=$Runtime
$info.Arguments='--load "'+(Join-Path $root 'engine/test-candidate-hygiene.el')+'"'
$info.WorkingDirectory=$root
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true
$info.RedirectStandardError=$true
$info.EnvironmentVariables['LOCALAPPDATA']=$run
$info.EnvironmentVariables['DDSKK_USER_JISYO']=$jisyo
$process=[Diagnostics.Process]::new()
$process.StartInfo=$info
try {
  [void]$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync()
  $stderr=$process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(180000)) {throw 'Private hygiene test timed out'}
  Write-Output $stdout.GetAwaiter().GetResult()
  Write-Output $stderr.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) {throw "Private hygiene test exit $($process.ExitCode)"}
} finally {
  if ($process.Id -and -not $process.HasExited) {$process.Kill(); $process.WaitForExit()}
  $process.Dispose()
}
