[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [Parameter(Mandatory)][string]$RepositoryPath,
  [Parameter(Mandatory)][string]$ArtifactDirectory,
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryPath)
$build = [IO.Path]::GetFullPath($BuildDirectory)
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$saved = @{}
foreach ($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS',
                    'NATIVEIME_TEST_OKURI_SYNC_FAIL_MS','NATIVEIME_TEST_OKURI_SYNC_DELAY_MS')) {
  $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$assertions = 0
try {
  $env:DDSKK_DICTIONARY_FILES = Join-Path $root 'windows/test-host/data/okuri-jisyo.utf8'
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  $cases = @(
    @{ Name='timeout'; Delay='fail'; Script='K a K u WAIT100 SETTLE30000:WRITE SPACE SETTLE30000:NEXT ENTER SETTLE30000:COMMIT K i e R u ENTER SETTLE30000:QUEUED';
       Expected=@{ WAIT100='25bd304b002a304f'; WRITE='25bc66f8304f'; NEXT='25bc639b304f'; COMMIT='639b304f'; QUEUED='639b304f6d883048308b' } },
    @{ Name='backspace'; Delay='fail'; Script='K a K BS SETTLE30000:PREFIX K u SETTLE30000:BACK ENTER SETTLE30000:COMMIT';
       Expected=@{ PREFIX='25bd304b002a'; BACK='25bc66f8304f'; COMMIT='66f8304f' } },
    @{ Name='late'; Delay='reply'; Script='K a K u WAIT100 CTRLG WAIT6500 K i e R u SETTLE30000:NEW ENTER SETTLE30000:COMMIT';
       Expected=@{ WAIT100='25bd304b002a304f'; WAIT6500=''; NEW='25bc6d883048308b'; COMMIT='6d883048308b' } }
  )
  foreach ($case in $cases) {
    $env:NATIVEIME_TEST_OKURI_SYNC_FAIL_MS = if ($case.Delay -eq 'fail') { '5500' } else { '' }
    $env:NATIVEIME_TEST_OKURI_SYNC_DELAY_MS = if ($case.Delay -eq 'reply') { '5500' } else { '' }
    $private = Join-Path $ArtifactDirectory $case.Name
    $lines = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'windows/test-host/run-harness.ps1') `
      -Script $case.Script -RepositoryPath $root -DllPath (Join-Path $build 'ddskk-ime.dll') `
      -CoreDllPath (Join-Path $build 'ddskk-ime-core.dll') -TsfHostExe (Join-Path $build 'tsf-host.exe') `
      -EngineHostPath (Join-Path $build 'ddskk-engine-host.exe') -EngineExecutablePath $EngineExecutablePath `
      -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory $private -TsfHostTimeoutSec 150 2>&1)
    $lines | Set-Content (Join-Path $ArtifactDirectory ($case.Name + '.log')) -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "Harness failed: $($case.Name)" }
    foreach ($label in $case.Expected.Keys) {
      $checkpoint = @($lines | Where-Object { $_ -match ('^AFTER ' + $label + ' BUF=') })
      if ($checkpoint.Count -ne 1 -or $checkpoint[0] -notmatch 'BUF=\[(.*)\] SEL=') { throw "Missing $label" }
      $actual = -join ($Matches[1].ToCharArray() | ForEach-Object { '{0:x4}' -f [int]$_ })
      if ($actual -ne $case.Expected[$label]) { throw "Mismatch $($case.Name)/$label expected=$($case.Expected[$label]) actual=$actual" }
      $assertions++
      Write-Output "MATCH $($case.Name)/$label text=$actual"
    }
    if (-not ($lines -match '^OKURI_TEST .*delay_ms=5500')) { throw 'Fault injection did not execute' }
    $assertions++
    if ($case.Name -eq 'late') {
      # Cleanup observes the parked prefix produced by the delayed SyncKeys
      # reply, proving that a real reply arrived after local cancellation.
      if (-not ($lines -match '^ENGINE_RELEASE ok=1 .*0025bd00304b00002a')) {
        throw 'Delayed engine reply was not observed by cleanup'
      }
      $assertions++
    }
    $latencies = @($lines | ForEach-Object {
      if ($_ -match '^KEYLAT token=(?:[A-Za-z]|BS|CTRLG) .*total_us=(\d+) ') { [int]$Matches[1] }
    })
    $maximum = ($latencies | Measure-Object -Maximum).Maximum
    if (-not $latencies.Count -or $maximum -gt 25000) { throw "Key exceeded 25 ms: $maximum us" }
    $assertions++
    Write-Output "LATENCY $($case.Name) max_us=$maximum"
  }
  Write-Output "PASS okuri handoff assertions=$assertions cases=3 delay_ms=5500"
} finally {
  foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
