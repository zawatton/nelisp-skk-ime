param(
  [switch]$SkipRegistrationCheck,
  [switch]$KeepHost
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$hostExe = Join-Path $repo 'build\windows\Debug\ddskk-engine-host.exe'
$clientTest = Join-Path $repo 'build\windows\Debug\ddskk-engine-client-test.exe'
$nelisp = (Resolve-Path (Join-Path $repo '..\nelisp\target\nelisp.exe')).Path
$clsid = '{80B44B14-B866-4EF4-A394-4FF1D87D5185}'
$classKey = "Registry::HKEY_LOCAL_MACHINE\Software\Classes\CLSID\$clsid"
$userClassKey = "Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\$clsid"

foreach ($path in @($hostExe, $clientTest, $nelisp)) {
  if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $path" }
}
if (-not $SkipRegistrationCheck -and
    -not (Test-Path -LiteralPath $classKey) -and
    -not (Test-Path -LiteralPath $userClassKey)) {
  throw 'DDSKK IME is not registered. Run register-debug.ps1 first.'
}

$hostProcess = $null
try {
  $hostProcess = Start-Process -FilePath $hostExe `
    -ArgumentList @($nelisp, $repo) -WorkingDirectory $repo `
    -WindowStyle Hidden -PassThru
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  $ready = $false
  while ([DateTime]::UtcNow -lt $deadline -and -not $hostProcess.HasExited) {
    try {
      $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'ddskk-ime-v1',
        [IO.Pipes.PipeDirection]::InOut)
      $pipe.Connect(250)
      $pipe.Dispose()
      $ready = $true
      break
    } catch {
      Start-Sleep -Milliseconds 250
    }
  }
  if (-not $ready) { throw 'DDSKK engine host did not open its named pipe.' }

  Write-Host 'DDSKK engine host is ready.'
  Write-Host 'Select "DDSKK (NeLisp)" from the Windows input switcher.'
  Write-Host 'Test in Notepad: kana -> かな, Kana -> ▽かな, Space -> ▼ candidate, Enter -> commit.'
  Write-Host 'Press Enter here after the interactive test.'
  Read-Host | Out-Null
} finally {
  if ($hostProcess -and -not $KeepHost) {
    if (-not $hostProcess.HasExited) { Stop-Process -Id $hostProcess.Id -Force }
    Get-CimInstance Win32_Process |
      Where-Object { $_.ParentProcessId -eq $hostProcess.Id -and $_.Name -eq 'nelisp.exe' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
}
