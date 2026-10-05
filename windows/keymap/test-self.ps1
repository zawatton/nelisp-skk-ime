param([Parameter(Mandatory)][string]$Exe,[switch]$Editor)
$ErrorActionPreference='Stop'
$privateId='KeymapTest-'+[guid]::NewGuid().ToString('N')
$root=Join-Path ([IO.Path]::GetTempPath()) $privateId
$settings='Software\NativeIME-Tests\'+$privateId
New-Item -ItemType Directory $root | Out-Null
$oldKey=$env:NATIVEIME_REGISTRY_KEY; $oldFile=$env:NELISP_IME_KEYMAP_FILE
try {
 $env:NATIVEIME_REGISTRY_KEY=$settings; $env:NELISP_IME_KEYMAP_FILE=Join-Path $root 'keymap.conf'
 $fixture="# fixture comment`nenabled = yes`nlayout = os`npass-injected = yes`nunknown = keep`n[keys]`nCapsLock = LCtrl # note`n[shortcuts]`nLAlt+Space = ime-toggle`nCtrl+Space = LWin+Space`n[exclude]`nmstsc.exe`n"
 # Unknown-line preservation is exercised by the UI; hook self-test uses a valid file.
 if(-not $Editor){$fixture=$fixture.Replace("unknown = keep`n",'')}
 [IO.File]::WriteAllText($env:NELISP_IME_KEYMAP_FILE,$fixture,[Text.UTF8Encoding]::new($false))
 if($Editor){& $Exe --editor --self-test-ui}else{& $Exe --self-test}
 if($LASTEXITCODE -ne 0){throw "self-test exit $LASTEXITCODE"}
} finally {
 $resolved=[IO.Path]::GetFullPath($root);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase)){throw 'Cleanup target escaped the private temp root'}
 $env:NATIVEIME_REGISTRY_KEY=$oldKey; $env:NELISP_IME_KEYMAP_FILE=$oldFile
 Remove-Item -LiteralPath ('HKCU:\'+$settings) -Recurse -Force -ErrorAction SilentlyContinue
 Remove-Item -LiteralPath $root -Recurse -Force
}
