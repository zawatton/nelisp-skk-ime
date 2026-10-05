param([Parameter(Mandatory)][string]$LogPath)
$ErrorActionPreference='Stop'
$text=[IO.File]::ReadAllText([IO.Path]::GetFullPath($LogPath))
$checks=@(
 'AFTER PAREN BUF=\[\u25bd\u304b\(\] SEL=3,3 COMP=0,3',
 'AFTER BRACKET BUF=\[\u25bd\u304b\(\u300c\] SEL=4,4 COMP=0,4',
 'AFTER WAIT3000 BUF=\[\u25bc\u868a\] SEL=2,2 COMP=0,2',
 'AFTER WAIT500 BUF=\[\u868a\u300c\u300d\] SEL=2,2 COMP=-'
)
foreach($pattern in $checks){if($text -notmatch $pattern){throw "Pair mode mismatch: $pattern"}}
Write-Output "PASS input rules preedit/candidate assertions=$($checks.Count)"
