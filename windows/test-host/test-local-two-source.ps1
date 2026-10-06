[CmdletBinding()]
param([Parameter(Mandatory)][string]$Runtime,
      [string]$BuildDir='build/w', [int]$ColdLoadSleepSec=45)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$build=[IO.Path]::GetFullPath((Join-Path $root $BuildDir))
$run=Join-Path $build ('local-two-source-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $run | Out-Null
$utf8=[Text.UTF8Encoding]::new($false)
$first=Join-Path $run 'first.utf8'; $second=Join-Path $run 'second.utf8'
$headers=";; okuri-ari entries.`n;; okuri-nasi entries.`n"
# Configured L-shaped sources only. The harness creates an empty private
# learning dictionary; neither tested reading is seeded into that dictionary.
[IO.File]::WriteAllText($first,$headers+"おーむ /Ω/王蟲/`nいどう /移動/異動;†「人事-」/`nいどう /井道/`n",$utf8)
[IO.File]::WriteAllText($second,$headers+"おーむ /Ω/王蟲;later/オーム/`nいどう /移動/異動;later/異同;†difference.「諸写本の-」/医道/`n",$utf8)
$saved=@{}
foreach($name in @('HOME','DDSKK_DICTIONARY_FILES','DDSKK_USER_JISYO','DDSKK_HARNESS_DIAGNOSTICS','LOCAL_ORACLE_DIR')) {
 $saved[$name]=[Environment]::GetEnvironmentVariable($name)
}
try {
 $env:DDSKK_DICTIONARY_FILES=$first+';'+$second
 $env:DDSKK_USER_JISYO=Join-Path $run 'empty-private.jisyo'
 $env:LOCAL_ORACLE_DIR=$run
 $env:DDSKK_HARNESS_DIAGNOSTICS='1'
 $oracleScript=Join-Path $run 'stock.el'
 [IO.File]::WriteAllText($oracleScript,@'
(let* ((sources (split-string (getenv "DDSKK_DICTIONARY_FILES") ";" t))
       (coding-system-for-write 'utf-8-unix) rows)
  (dolist (reading '("おーむ" "いどう"))
    (let ((words (lfd1-oracle--stock sources reading)))
      (unless (= (length words) 4) (error "Expected four stock candidates: %S" words))
      (push (concat (lfd1-oracle--hex reading) " "
                    (mapconcat #'lfd1-oracle--hex words ",") "\n") rows)))
  (write-region (apply #'concat (nreverse rows)) nil
                (expand-file-name "two-source.oracle" (getenv "LOCAL_ORACLE_DIR"))))
'@,$utf8)
 $env:HOME=[Environment]::GetFolderPath('UserProfile');
 $oracle=Start-Process -FilePath 'emacs' -WindowStyle Hidden -Wait -PassThru `
  -ArgumentList @('-Q','--batch','-L',('"'+(Join-Path $root 'vendor/ddskk')+'"'),'-L',('"'+(Join-Path $root 'engine')+'"'),
    '-l',('"'+(Join-Path $root 'engine/test-local-conversion-oracle.el')+'"'),'-l',('"'+$oracleScript+'"')) `
  -RedirectStandardOutput (Join-Path $run 'stock.stdout.log') -RedirectStandardError (Join-Path $run 'stock.stderr.log')
 if($oracle.ExitCode -ne 0){throw "Stock oracle failed: $run"}
 $keys='CTX2 a i SPACE WAIT3000 ENTER CTX1 O - m u SPACE SETTLE8000:O0 MIRROR SPACE SETTLE8000:O1 SPACE SETTLE8000:O2 SPACE SETTLE8000:O3 CTRLG CTRLG APPCLEAR I d o u SPACE SETTLE8000:I0 MIRROR SPACE SETTLE8000:I1 SPACE SETTLE8000:I2 SPACE SETTLE8000:I3 ENTER SETTLE8000:END'
 $log=Join-Path $run 'harness.log'
 & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'run-harness.ps1') `
  -Script $keys -EngineHostPath (Join-Path $build 'Release/ddskk-engine-host.exe') -EngineExecutablePath $Runtime `
  -RepositoryPath $root -DllPath (Join-Path $build 'Release/ddskk-ime.dll') -CoreDllPath (Join-Path $build 'Release/ddskk-ime-core.dll') `
  -TsfHostExe (Join-Path $build 'Release/tsf-host.exe') -LocalConversion 1 -ColdLoadSleepSec $ColdLoadSleepSec -ArtifactDirectory $run *> $log
 if($LASTEXITCODE -ne 0){throw "Two-source harness failed: $log"}
 $text=[IO.File]::ReadAllText($log); $checks=0
 $rows=@([IO.File]::ReadAllLines((Join-Path $run 'two-source.oracle')))
 $mirrors=@([regex]::Matches($text,'MIRROR stable=1 line=(STATE [^\r\n]+)') | ForEach-Object {$_.Groups[1].Value})
 if($rows.Count -ne 2 -or $mirrors.Count -ne 2){throw "Missing stock rows or mirrors: $log"}
 for($r=0;$r -lt 2;$r++) {
  $vector=$rows[$r].Split(' ')[1]; $words=$vector.Split(',')
  if(-not $mirrors[$r].EndsWith(' 0 '+$vector)){throw "Local vector differs from stock row $r`: $log"}; $checks++
  for($i=0;$i -lt 4;$i++) {
   $word=''; for($n=0;$n -lt $words[$i].Length;$n+=6){$word+=[char][Convert]::ToInt32($words[$i].Substring($n,6),16)}
   $word=$word.Split(';')[0]; $label=@('O','I')[$r]+$i
   if($text -notmatch ('AFTER '+$label+' BUF=\[▼'+[regex]::Escape($word)+'\]')){throw "Stock candidate $label mismatch: $log"}; $checks++
  }
 }
 if(@([regex]::Matches($text,'branch=local-convert ')).Count -ne 2 -or $text -match 'branch=provider-(convert|queue|accept-and-queue)|SETTLE TIMEOUT'){throw "Readings did not stay local: $log"}; $checks++
 if($text -notmatch 'AFTER END BUF=\[医道\] SEL=.* COMP=-'){throw "Stock annotation-free commit mismatch: $log"}; $checks++
 Write-Output "PASS local two-source readings=2 candidates=8 checks=$checks stock_order=1 local_path=1 log=$log"
} finally {foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
