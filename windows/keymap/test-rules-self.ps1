param([Parameter(Mandatory)][string]$Exe)
$ErrorActionPreference='Stop'
$id='RulesTest-'+[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) $id
$settings='Software\NativeIME-Tests\'+$id
$oldKey=$env:NATIVEIME_REGISTRY_KEY; $oldRules=$env:NELISP_IME_INPUT_RULES
New-Item -ItemType Directory $root | Out-Null
try {
 $env:NATIVEIME_REGISTRY_KEY=$settings; $env:NELISP_IME_INPUT_RULES=Join-Path $root 'input-rules.conf'
 [IO.File]::WriteAllText($env:NELISP_IME_INPUT_RULES,"# keep comment`nwidth = hankaku # width comment`n[symbols-hankaku]`n. = `". `" # keep comment`n",[Text.UTF8Encoding]::new($false))
 & $Exe --rules --self-test-ui
 if($LASTEXITCODE -ne 0){throw "rules self-test exit $LASTEXITCODE"}
} finally {
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target escaped the private temp root'}
 $env:NATIVEIME_REGISTRY_KEY=$oldKey; $env:NELISP_IME_INPUT_RULES=$oldRules
 Remove-Item -LiteralPath ('HKCU:\'+$settings) -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $root -Recurse -Force
}
