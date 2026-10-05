[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$BuildDirectory,
  [Parameter(Mandatory)][string]$EngineExecutablePath,
  [Parameter(Mandatory)][string]$RepositoryPath,
  [string]$ArtifactDirectory = '',
  [string]$DllPath = '',
  [int]$ColdLoadSleepSec = 45
)
$ErrorActionPreference = 'Stop'
$BuildDirectory = [IO.Path]::GetFullPath($BuildDirectory)
$RepositoryPath = [IO.Path]::GetFullPath($RepositoryPath)
if (-not $DllPath) { $DllPath = Join-Path $BuildDirectory 'ddskk-ime.dll' }
if (-not $ArtifactDirectory) { $ArtifactDirectory = Join-Path $RepositoryPath 'build/validation/hot-swap-core' }
New-Item -ItemType Directory -Path $ArtifactDirectory -Force | Out-Null
$assertions = 0
function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
  $script:assertions++
}
# Each CORE token writes the private registry from inside the same TSF host.
# Switch during reading and candidate selection; queued keys must retain order.
$keys = 'a CORE:B WAIT700 a K a CORE:production WAIT700 n a SPACE WAIT3000 ENTER WAIT700 a K a SPACE WAIT3000 CORE:B WAIT700 ENTER WAIT700 a K a SPACE CORE:production WAIT100 ENTER WAIT1500 a CORE:B WAIT700 a CORE:bad-abi WAIT700 a CORE:bad-init WAIT700 a CORE:missing WAIT700 a CORE:B WAIT700 CORE:DEPLOY a CORE:ROLLBACK a q CLIENT IMEOFF CORE:production WAIT700 CLIENT IMEON CLIENT q CLIENT'
$savedDiagnostics = $env:DDSKK_HARNESS_DIAGNOSTICS
try {
  $env:DDSKK_HARNESS_DIAGNOSTICS = '1'
  $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
    -Script $keys -DllPath $DllPath `
    -TsfHostExe (Join-Path $BuildDirectory 'tsf-host.exe') `
    -EngineHostPath (Join-Path $BuildDirectory 'ddskk-engine-host.exe') `
    -EngineExecutablePath $EngineExecutablePath -RepositoryPath $RepositoryPath `
    -CoreTestDirectory $BuildDirectory -ArtifactDirectory $ArtifactDirectory `
    -ColdLoadSleepSec $ColdLoadSleepSec -PublishState 2>&1)
  $lines | Set-Content -LiteralPath (Join-Path $ArtifactDirectory 'core-hot-swap.log') -Encoding UTF8
  $lines | ForEach-Object { Write-Output $_ }
  Require ($LASTEXITCODE -eq 0) 'Harness failed'
  $text = $lines -join "`n"
  $pids = @($lines | Where-Object { $_ -match '^CORE(?:KEY|_REQUEST| )' -and $_ -match 'pid=(\d+)' } |
    ForEach-Object { if ($_ -match 'pid=(\d+)') { $Matches[1] } } | Select-Object -Unique)
  Require ($pids.Count -eq 1) "Expected diagnostics from one TSF process; observed $($pids.Count)"
  Require ([bool]($text -match '(?s)COREKEY version=production.*CORE_REQUEST version=B.*CORE swapped version=B.*COREKEY version=B')) 'Idle A -> B did not switch real key dispatch'
  Require ([bool]($text -match '(?s)CORE_REQUEST version=production.*AFTER WAIT700 BUF=\[\u3042\u3042\u25bd\u304b\].*COREKEY version=B vk=4E.*COREKEY version=B vk=41.*COREKEY version=B vk=20.*COREKEY version=B vk=0D.*CORE swapped version=production.*COREKEY version=production vk=41')) 'Reading swap was not deferred through ordered commit'
  Require ([bool]($text -match '(?s)CORE_REQUEST version=B[^\n]*\nAFTER CORE:B BUF=\[[^\]]*\u25bc\u868a\].*COREKEY version=production vk=0D.*CORE swapped version=B.*COREKEY version=B vk=41')) 'Candidate swap was not deferred through commit'
  $pending = [regex]::Match($text, '(?s)AFTER SPACE[^\n]*\nCORE_REQUEST version=production.*?CORE swapped version=production').Value
  Require ($pending.Length -gt 0) 'No swap request immediately after provider dispatch'
  $flags = @([regex]::Matches($pending, 'CORE_QUIESCENCE flags=(\d+)') | ForEach-Object { [int]$_.Groups[1].Value })
  Require (@($flags | Where-Object { ($_ -band 8) -ne 0 }).Count -gt 0) 'Pending provider did not defer swap'
  $states = @($lines | Where-Object { $_ -match '^CLIENT mode=' })
  Require ($states.Count -eq 4) 'Missing migration state snapshots'
  Require ($states[0] -match 'mode=katakana open=1' -and $states[1] -match 'mode=katakana open=0' -and
    $states[2] -match 'mode=katakana open=1' -and $states[3] -match 'mode=hiragana open=1') 'Open/close or mode was lost across swap'
  $sequences = @($states | ForEach-Object { if ($_ -match 'sequence=(\d+)') { [int]$Matches[1] } })
  Require ($sequences[0] -lt $sequences[1] -and $sequences[1] -lt $sequences[2] -and $sequences[2] -lt $sequences[3]) 'Publication sequence regressed across swap'
  foreach ($reason in @('abi','init','load')) { Require ([bool]($text -match "CORE reject-$reason")) "Missing rejection reason $reason" }
  foreach ($bad in @('bad-abi','bad-init','missing')) {
    Require ([bool]($text -match "(?s)CORE_REQUEST version=$bad.*?CORE reject-swap version=B.*?COREKEY version=B vk=41")) "Core B did not survive $bad"
  }
  Require ([bool]($text -match 'AFTER a BUF=\[\u3042\u3042\u4eee\u540d\u3042\u868a\u3042\u868a\u3042\u3042\u3042\u3042\u3042\u3042\u3042\].*COMP=-')) 'Keys were lost or reordered'
  Require ([bool]($text -match '(?s)CORE_ACTION action=deploy[^\n]*exit=0.*?CORE swapped version=B.*?COREKEY version=B vk=41.*?CORE_ACTION action=rollback[^\n]*exit=0.*?CORE swapped version=B.*?COREKEY version=B vk=41')) 'Versioned deployment or rollback did not update the running client'
  $ordinary = @($lines | Where-Object { $_ -match '^KEYLAT token=[A-Za-z] .*total_us=(\d+) ' } |
    ForEach-Object { if ($_ -match 'total_us=(\d+)') { [int]$Matches[1] } })
  $maximum = ($ordinary | Measure-Object -Maximum).Maximum
  Require ($ordinary.Count -gt 0 -and $maximum -le 25000) "Ordinary key exceeded existing 25 ms limit: $maximum us"
  Write-Output "PASS core hot swap assertions=$assertions processes=$($pids.Count) ordinary_max_us=$maximum"
} finally {
  [Environment]::SetEnvironmentVariable('DDSKK_HARNESS_DIAGNOSTICS', $savedDiagnostics)
}
