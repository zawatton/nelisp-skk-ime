[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [Parameter(Mandatory)][string]$LargeDictionary,
      [string]$BuildDir='build/w', [string]$CoreDll='',
      [int]$ColdLoadSleepSec=45, [int]$Seed=20261006,
      [int]$Episodes=60)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-stress-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$utf8=New-Object Text.UTF8Encoding($false)
$personal=Join-Path $run 'synthetic-personal.utf8'
# Four keys, six duplicates, four descending adjacent pairs. No real personal data.
[IO.File]::WriteAllText($personal,"ていこうち /抵抗値/`nあたい /値/`nおーむ /Ω/オーム/`nかな /仮名/`nあたい /値/`nていこうち /抵抗値/`nおーむ /Ω/オーム/`nかな /仮名/`nあたい /値/`nていこうち /抵抗値/`nかk /書/掛/[く/書/掛/]/`nかt /買/飼/[った/買/飼/]/`nかu /買/[う/買/]/`nしn /死/[んだ/死/]/`n",$utf8)
$firstSource=Join-Path $run 'first-only.utf8'
$firstEntries=''
$vowels=@('a','i','u','e','o');$kana=@('あ','い','う','え','お')
function FirstReading([int]$number) {
 $letters=@();$syllables=@();$n=$number
 do {$digit=$n%5;$letters+=$vowels[$digit];$syllables+=$kana[$digit];$n=[int][Math]::Floor($n/5)} while($n -gt 0)
 return @{key='は'+($syllables -join '');tokens='H a '+($letters -join ' ')}
}
for($i=0;$i -lt $Episodes;$i++) {
 $firstEntries+=(FirstReading $i).key+' /初語'+$i+"/`n"
}
[IO.File]::WriteAllText($firstSource,$firstEntries,$utf8)
$saved=@{}
foreach($name in @('DDSKK_DICTIONARY_FILES','DDSKK_HARNESS_DIAGNOSTICS','NATIVEIME_TEST_LOCAL_WORKER_STALL_MS','NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS')) {
 $saved[$name]=[Environment]::GetEnvironmentVariable($name)
}
if(-not $CoreDll){$CoreDll=Join-Path $build 'Release/ddskk-ime-core.dll'}
try {
 $env:DDSKK_DICTIONARY_FILES=$personal+';'+$firstSource+';'+[IO.Path]::GetFullPath($LargeDictionary)
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 $env:NATIVEIME_TEST_LOCAL_WORKER_STALL_MS='5000'
 $env:NATIVEIME_TEST_LOCAL_PUBLICATION_STALL_MS='5000'
 $random=New-Object Random($Seed)
 $tokens='CTX2 a i SPACE WAIT3000 ENTER CTX1 '
 $expected=''; $candidateChecks=0; $firstChecks=0; $denialChecks=0
 for($i=0;$i -lt $Episodes;$i++) {
  $choice=$random.Next(9)
  $word=@('抵抗値','抵抗値','Ω','値','漢字','書く','買った','死んだ','買う')[$choice]
  $reading=@('T e i k o u c h i','T e i k o u t i','O - m u','A t a i','K a n j i','K a K u','K a T t a','S i N d a','K a U')[$choice]
  if($i % 3 -eq 0) {
   $choice=9;$firstChecks++
   $word='初語'+$i;$reading=(FirstReading $i).tokens
  }
  if($random.Next(4) -eq 0) {
   $denialChecks++
   if($choice -lt 5 -or $choice -eq 9){$tokens+=$reading+' DENYWRITE SPACE WAIT200 '}
   else {
    $parts=$reading.Split(' ');$last=$parts[-1]
    $tokens+=($parts[0..($parts.Count-2)] -join ' ')+' DENYWRITE '+$last+' '+$last+' '
   }
  } else {$tokens+=$reading+' '; if($choice -lt 5 -or $choice -eq 9){$tokens+='SPACE '}}
  # Traversal returns to the first identity; repeated commits preserve order.
  if($choice -ge 2 -and $choice -lt 9 -and $random.Next(2)) {$tokens+='SPACE x '}
  if($random.Next(3) -eq 0 -and $choice -lt 5) {$tokens+='CTRLG SPACE '}
  if($i % 4 -eq 0) {$tokens+='SETTLE8000:C'+$i+' '; $candidateChecks++}
  $tokens+='ENTER '
  $expected+=$word
  if($i -eq 10){$tokens+='WAIT6000 '} # ACK + publication after the stalled worker
  if($i -eq 30){$tokens+='KILLCHILD '} # Restart cannot steal a pinned local episode
 }
 $tokens+='SETTLE8000:END WAIT1500'
 $log=Join-Path $run 'stress.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
  -Script $tokens -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') `
  -EngineExecutablePath $Runtime -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') `
  -CoreDllPath $CoreDll -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') `
  -LocalConversion 1 -DebugLog -ColdLoadSleepSec $ColdLoadSleepSec -TsfHostTimeoutSec 180 -ArtifactDirectory $run *> $log
 if($LASTEXITCODE -ne 0){Get-Content $log -Tail 12; throw "Stress harness failed: $log"}
 $text=[IO.File]::ReadAllText($log)
 $after=@($text -split "`n" | Where-Object {$_ -match '^AFTER END BUF='})[-1]
 if($after -notmatch '^AFTER END BUF=\[(.*)\] SEL=' -or $Matches[1] -cne $expected) {
  throw "Stress commit mismatch: expected_chars=$($expected.Length) final=$after log=$log"
 }
 $checkpoints=@($text -split "`n" | Where-Object {$_ -match '^AFTER C\d+ BUF='})
 if($checkpoints.Count -ne $candidateChecks -or @($checkpoints | Where-Object {$_ -notmatch '▼.+\] SEL='}).Count) {throw "SPACE did not produce candidates: $log"}
 if($text -match 'SETTLE TIMEOUT|branch=provider-(queue|accept-and-queue|convert)|KEYBRANCH [^\r\n]*branch=local[^\r\n]*provider_pending=1') {throw "Local ownership stranded or replayed: $log"}
 if(@([regex]::Matches($text,'EDIT_DENIED sync=(0|1) flags=')).Count -ne $denialChecks -or
    @([regex]::Matches($text,'LOCAL_EDIT denied=1')).Count -ne $denialChecks) {throw "Every injected write refusal must be exercised: expected=$denialChecks log=$log"}
 if($text -notmatch 'LOCAL_WORKER stalled_ms=5000' -or $text -notmatch 'LOCAL_PUBLICATION stalled_ms=5000') {throw "Stall seam not exercised: $log"}
 if(@([regex]::Matches($text,'LOCAL publication status=')).Count -lt 2){throw "No generation swap: $log"}
 $times=@([regex]::Matches($text,'KEYLAT token=\S+ .*?total_us=(\d+) claimed=1') | ForEach-Object {[int]$_.Groups[1].Value})
 $maximum=($times | Measure-Object -Maximum).Maximum
 if(-not $times.Count -or $maximum -gt 25000){throw "Callback watchdog exceeded 25000 us: $maximum log=$log"}
 Write-Output "PASS local state stress seed=$Seed episodes=$Episodes commits=$Episodes first_time=$firstChecks candidate_checks=$candidateChecks write_refusals=$denialChecks callbacks=$($times.Count) max_us=$maximum log=$log"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
