# Headless config-file gate; the executable allocates and removes private files.
[CmdletBinding()]
param([string]$IndicatorExe = (Join-Path $PSScriptRoot '../target/sumi-skk-ui.exe'))
$ErrorActionPreference = 'Stop'
$runId = [guid]::NewGuid().ToString('N')
$out = Join-Path $env:TEMP "sumi-editor-$runId.out"
$err = Join-Path $env:TEMP "sumi-editor-$runId.err"
$proc = $null
try {
  $proc = Start-Process -FilePath ([IO.Path]::GetFullPath($IndicatorExe)) -ArgumentList '--editor-selftest' -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  if (-not $proc.WaitForExit(30000)) { throw 'text settings selftest timed out' }
  $proc.Refresh()
  $lines = @(Get-Content -LiteralPath $out)
  $lines | ForEach-Object { Write-Host $_ }
  Get-Content -LiteralPath $err | ForEach-Object { Write-Host $_ }
  $passes = @($lines -match '^PASS ').Count
  $fails = @($lines -match '^FAIL ').Count
  Write-Host "verify-editor: $passes PASS lines, $fails FAIL lines; exit $($proc.ExitCode)"
  if ($proc.ExitCode -ne 0 -or $fails -ne 0 -or -not ($lines -match '^EDITOR-SELFTEST-PASS')) { throw 'text settings selftest failed' }
} finally {
  if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  Remove-Item -LiteralPath $out,$err -ErrorAction SilentlyContinue
}
