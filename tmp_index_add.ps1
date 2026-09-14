$utf8 = New-Object System.Text.UTF8Encoding($false)
$paths = [System.IO.File]::ReadAllLines("C:\rebase\videoCRM\tmp_paths.txt", [System.Text.Encoding]::UTF8)
$idx = $paths[1]
$newline = ([System.IO.File]::ReadAllText("C:\rebase\videoCRM\tmp_index_line.txt", [System.Text.Encoding]::UTF8)).TrimEnd("`r","`n")

$lines = [System.Collections.Generic.List[string]]([System.IO.File]::ReadAllLines($idx, [System.Text.Encoding]::UTF8))
$hit = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -like '###*videoCRM*') { $hit = $i; break }
}
if ($hit -lt 0) {
  Write-Output "NO videoCRM SECTION"
} elseif ($lines -contains $newline) {
  Write-Output "ALREADY PRESENT"
} else {
  $lines.Insert($hit + 1, $newline)
  [System.IO.File]::WriteAllLines($idx, $lines, $utf8)
  Write-Output "OK inserted after line $hit : $($lines[$hit])"
}
