$utf8 = New-Object System.Text.UTF8Encoding($false)
$paths = [System.IO.File]::ReadAllLines("C:\rebase\videoCRM\tmp_paths.txt", [System.Text.Encoding]::UTF8)
$dst = $paths[0]
$idx = $paths[1]
$text = [System.IO.File]::ReadAllText("C:\rebase\videoCRM\tmp_lesson.md", [System.Text.Encoding]::UTF8)

if (Test-Path -LiteralPath $dst) {
  [System.IO.File]::AppendAllText($dst, $text, $utf8)
  Write-Output "OK appended lesson"
} else {
  Write-Output "MISSING dst"
}
if (Test-Path -LiteralPath $idx) { Write-Output "OK index exists" } else { Write-Output "MISSING index" }
