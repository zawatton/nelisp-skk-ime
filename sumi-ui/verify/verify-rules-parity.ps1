[CmdletBinding()]
param([string]$IndicatorExe=(Join-Path $PSScriptRoot '../target/sumi-skk-ui.exe'))
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$dir=Join-Path $root ('build/validation/sumi-settings/sn3-parity-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
$saved=@{}
foreach($n in @('NATIVEIME_REGISTRY_KEY','NELISP_IME_INPUT_RULES','SUMI_TEST_ROOT','SUMI_TEST_CORPUS','HOME')){$saved[$n]=[Environment]::GetEnvironmentVariable($n)}
$cases=@('',"bad`n", "width = bad`n", "auto-pair = bad`n", "width = yes no`n", "wat = yes`n",
 "[wat]`na = `"x`"`n", "[symbols-hankaku]`na = `"x`" `"y`"`n", "[symbols-hankaku]`na = x`n",
 "[symbols-hankaku]`n`"`" = `"x`"`n", "[symbols-hankaku]`nあ = `"x`"`n", "[pairs]`na = `"`" `"x`"`n",
 'a = "x\', 'a = "x\n"', 'a = "x',
 "width = hankaku`nwidth = `"zenkaku`" # last`nauto-pair = no`n[symbols-hankaku]`n. = `"first`"`n. = `"last`"`n",
 "`"[pairs]`"`n`"#`" = `"<`" `">`" # comment`n",
 "[symbols-zenkaku]`n`"z `" = `" `"`n",
 "[pairs]`n`"quote`" = `"\`"`" `"\\`"`n",
 "[symbols-hankaku]`n. = `"`"`n[pairs]`n`"`" = `"`" no`n")
try {
 for($i=0;$i -lt $cases.Count;$i++){[IO.File]::WriteAllText((Join-Path $dir ('{0:d2}.conf' -f $i)),$cases[$i],[Text.UTF8Encoding]::new($false))}
 $env:SUMI_TEST_ROOT=$root;$env:SUMI_TEST_CORPUS=$dir
 $env:HOME=[Environment]::GetFolderPath('UserProfile');
 & emacs -Q --batch -l (Join-Path $PSScriptRoot 'rules-parser-oracle.el')
 if($LASTEXITCODE -ne 0){throw 'Engine oracle failed'}
 $env:NATIVEIME_REGISTRY_KEY='Software\NativeIME-Tests\SN3-parity-'+[guid]::NewGuid().ToString('N')
 $count=0
 foreach($file in Get-ChildItem -LiteralPath $dir -Filter '*.conf'){
  $env:NELISP_IME_INPUT_RULES=$file.FullName
  $out=$file.FullName+'.actual';$err=$file.FullName+'.err'
  $p=Start-Process -FilePath ([IO.Path]::GetFullPath($IndicatorExe)) -ArgumentList '--rules-parse-selftest' -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
  try {
   if(-not $p.WaitForExit(10000)){throw 'AOT parser timeout'}
   if($p.ExitCode -ne 0){throw "AOT parser exit $($p.ExitCode)"}
   $actual=@(Get-Content -LiteralPath $out | Sort-Object -CaseSensitive)
   $expected=@(Get-Content -LiteralPath ($file.FullName+'.expected') | Sort-Object -CaseSensitive)
   if(Compare-Object $actual $expected -CaseSensitive){throw "Parser mismatch: $($file.Name)"}
   $count++;Write-Output "PASS engine-parser-parity $($file.Name)"
  }finally{if(-not $p.HasExited){Stop-Process -Id $p.Id -Force;$p.WaitForExit()}}
 }
 Write-Output "verify-rules-parity: $count PASS, 0 FAIL"
}finally{foreach($n in $saved.Keys){[Environment]::SetEnvironmentVariable($n,$saved[$n])}}
