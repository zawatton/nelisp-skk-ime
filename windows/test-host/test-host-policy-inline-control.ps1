[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,[string]$BuildDir='build/w',
      [int]$ColdLoadSleepSec=45,
      [ValidateRange(1,20)][int]$RepeatCount=1,
      [ValidateSet('OFF','SOURCES','CACHE','RESTART','PUBLICATION','LEARNING','ALL','SHADOW')]
      [string[]]$Cases=@('OFF','SOURCES','CACHE','RESTART','PUBLICATION','LEARNING','ALL','SHADOW'),
      [ValidateSet('','9')][string]$PauseKind='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$bin=Join-Path $root "$BuildDir/Release"
$run=Join-Path $root ($BuildDir+'/inline-policy-control-'+[guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory $run)
$switches=@('SOURCES','CACHE','RESTART','PUBLICATION','LEARNING')
$names=@($switches | ForEach-Object {'DDSKK_HOST_POLICY_'+$_})+@(
  'DDSKK_HOST_POLICY_SHADOW','DDSKK_HOST_POLICY_TEST_PAUSE_KIND',
  'NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS','HOME')
$saved=@{};foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$results=@()
try {
  for($iteration=1;$iteration -le $RepeatCount;$iteration++){
  foreach($case in $Cases){
    $caseDirectory=if($RepeatCount -eq 1){$case}else{'{0}-{1:D2}' -f $case,$iteration}
    foreach($switch in $switches){
      [Environment]::SetEnvironmentVariable('DDSKK_HOST_POLICY_'+$switch,
        $(if($case -eq 'ALL' -or $case -eq $switch){'1'}else{'0'}))
    }
    $env:DDSKK_HOST_POLICY_SHADOW=$(if($case -eq 'SHADOW'){'1'}else{'0'})
    [Environment]::SetEnvironmentVariable('DDSKK_HOST_POLICY_TEST_PAUSE_KIND',$PauseKind)
    Remove-Item Env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS -ErrorAction SilentlyContinue
    $env:HOME=[Environment]::GetFolderPath('UserProfile')
    $arguments=@((Join-Path $PSScriptRoot 'test-inline-preedit.py'),
      '--dll',(Join-Path $bin 'ddskk-ime.dll'),'--core',(Join-Path $bin 'ddskk-ime-core.dll'),
      '--tsf-host',(Join-Path $bin 'tsf-host.exe'),'--engine-host',(Join-Path $bin 'ddskk-engine-host.exe'),
      '--runtime',$Runtime,'--artifacts',(Join-Path $run $caseDirectory),'--case','emacs',
      '--cold-load',"$ColdLoadSleepSec",'--repository',$root)
    $before=@(Get-Process nelisp,ddskk-engine-host,tsf-host -ErrorAction SilentlyContinue | ForEach-Object Id)
    $log=Join-Path $run ($caseDirectory+'.log')
    Write-Output "CASE=$case ITERATION=$iteration PAUSE_KIND=$PauseKind SHADOW=$env:DDSKK_HOST_POLICY_SHADOW"
    foreach($switch in $switches){Write-Output ('env: DDSKK_HOST_POLICY_'+$switch+'='+[Environment]::GetEnvironmentVariable('DDSKK_HOST_POLICY_'+$switch))}
    Write-Output ('cmd: python '+($arguments -join ' '))
    & python @arguments *> $log
    $code=$LASTEXITCODE
    Get-Content -LiteralPath $log -Tail 4
    $remaining=@(Get-Process nelisp,ddskk-engine-host,tsf-host -ErrorAction SilentlyContinue | Where-Object {$before -notcontains $_.Id})
    if($remaining.Count){
      $attribution=& python (Join-Path $PSScriptRoot 'host-test-process-guard.py') --root $root @($remaining.Id)
      if($LASTEXITCODE -ne 0){throw 'Process attribution failed'}
      $owned=$attribution | ConvertFrom-Json
      if($owned.remaining.Count){throw "Refuse next stack: owned/unknown IME processes remain ($($owned.remaining -join ','))"}
    }
    $text=Get-Content -LiteralPath $log -Raw
    $status=if($code -eq 0){'PASS'}elseif($text -match 'registry key.*denied|UnauthorizedAccessException'){'BLOCKED'}else{'FAIL'}
    $trace=@(Get-ChildItem -LiteralPath (Join-Path $run $caseDirectory) -Filter host.log -Recurse -File |
      ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw}) -join "`n"
    $used=[regex]::Matches($trace,'policy-authoritative kind=(\d+) count=(\d+)') |
      ForEach-Object {$_.Groups[1].Value+':'+$_.Groups[2].Value}
    $differences=[regex]::Matches($trace,'policy-authoritative-difference').Count
    $mismatches=[regex]::Matches($trace,'policy-compare mismatch').Count
    $replacements=[regex]::Matches($trace,'replacement-published').Count
    $accounting=$trace -match 'policy-decision-accounting v=1'
    $results+= [pscustomobject]@{Case=$case;Iteration=$iteration;Status=$status;Exit=$code;Log=$log;
      ConsumedKinds=@($used);AccountingAvailable=$accounting;Differences=$differences;
      ReplyMismatches=$mismatches;Replacements=$replacements}
    Write-Output "EVIDENCE case=$case consumed_kinds=$($used -join ',') accounting=$accounting differences=$differences reply_mismatches=$mismatches replacements=$replacements"
    Write-Output "RESULT inline policy=$case status=$status exit=$code log=$log"
  }
  }
  $results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'results.json') -Encoding utf8
  $results | Format-Table Case,Iteration,Status,Exit
  if(@($results | Where-Object {$_.Status -ne 'PASS'}).Count){throw "Inline policy control incomplete/red: $run"}
} finally {
  foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
}
