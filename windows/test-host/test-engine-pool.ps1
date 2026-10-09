[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w',
      [string]$Cases='windows/test-host/conversion-corpus.json',
      [switch]$FreshCheck,
      [switch]$NegativeControl)
# Replays engine conversion cases in ONE reused DDSKK engine through
# NeLisp's nelisp-service pool (engine/engine-pool-run.el) instead of
# starting an engine per run.  -FreshCheck also replays every case in a
# fresh engine and requires identical replies; -NegativeControl omits
# RESET between cases and must therefore FAIL.  The runtime must ship
# packages/nelisp-service (sibling ../nelisp checkout by default, or
# $env:NELISP_SERVICE_SRC).
$ErrorActionPreference='Stop'
# Resolve a relative -Runtime against the caller's directory before the
# child runs with the repository root as its working directory.
$Runtime=[IO.Path]::GetFullPath($Runtime, (Get-Location).ProviderPath)
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$private=Join-Path (Join-Path $root $BuildDir) ('engine-pool-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $private)
$info=[Diagnostics.ProcessStartInfo]::new()
$info.FileName=$Runtime
$info.Arguments='--load "'+(Join-Path $root 'engine/engine-pool-run.el')+'"'
$info.WorkingDirectory=$root
$info.UseShellExecute=$false; $info.CreateNoWindow=$true
$info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
$info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false)
$info.EnvironmentVariables['ENGINE_POOL_PRIVATE']=$private
$info.EnvironmentVariables['ENGINE_POOL_CASES']=$Cases
$info.EnvironmentVariables['ENGINE_POOL_FRESH_CHECK']=$(if($FreshCheck -or $NegativeControl){'1'}else{'0'})
$info.EnvironmentVariables['ENGINE_POOL_SKIP_RESET']=$(if($NegativeControl){'1'}else{'0'})
$process=[Diagnostics.Process]::new(); $process.StartInfo=$info
try {
  [void]$process.Start()
  $process.StandardInput.Close()
  $stdout=$process.StandardOutput.ReadToEndAsync()
  $stderr=$process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit(900000)) {throw 'engine pool run timed out'}
  $out=$stdout.GetAwaiter().GetResult()
  Write-Output $out
  $err=$stderr.GetAwaiter().GetResult()
  if ($err) {Write-Output $err}
  $passed=$out -match '(?m)^ENGINE-POOL-PASS\r?$'
  if ($NegativeControl) {
    if ($passed -or -not ($out -match '(?m)^ENGINE-POOL-FAIL\r?$')) {
      throw 'negative control was not rejected'
    }
    Write-Output 'PASS engine pool negative control rejected leaked state'
  } elseif (-not $passed) {
    throw 'engine pool run failed'
  }
} finally {
  if ($process.Id -and -not $process.HasExited) {$process.Kill(); $process.WaitForExit()}
  $process.Dispose()
  Remove-Item -LiteralPath $private -Recurse -Force -ErrorAction SilentlyContinue
}
