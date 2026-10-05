[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime, [string]$BuildDir='build/w')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$run=Join-Path (Join-Path $root $BuildDir) ('replay-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=$Runtime
$info.Arguments='--load "'+(Join-Path $root 'engine/test-conversion-round2.el')+'"'
$info.WorkingDirectory=$root
$info.UseShellExecute=$false
$info.CreateNoWindow=$true
$info.RedirectStandardOutput=$true
$info.RedirectStandardError=$true
$info.EnvironmentVariables['LOCALAPPDATA']=$run
$info.EnvironmentVariables['DDSKK_USER_JISYO']=Join-Path $run 'user.jisyo'
$info.EnvironmentVariables['DDSKK_SKKSERV_ENABLE']='0'
$info.EnvironmentVariables['DDSKK_SKKSERV_START_COMMAND']=''
$process=[Diagnostics.Process]::new()
$process.StartInfo=$info
try {
  [void]$process.Start()
  $stdout=$process.StandardOutput.ReadToEndAsync()
  $stderr=$process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(180000)) {throw 'Private replay test timed out'}
  Write-Output $stdout.GetAwaiter().GetResult()
  Write-Output $stderr.GetAwaiter().GetResult()
  if ($process.ExitCode -ne 0) {throw "Private replay test exit $($process.ExitCode)"}
} finally {
  if ($process.Id -and -not $process.HasExited) {$process.Kill(); $process.WaitForExit()}
  $process.Dispose()
}
