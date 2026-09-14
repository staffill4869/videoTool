$deadline = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $deadline) {
  $p = Get-Process ffmpeg -ErrorAction SilentlyContinue
  if (-not $p) { Write-Output "ffmpeg idle"; exit 0 }
  Start-Sleep -Seconds 30
}
Write-Output "timeout waiting for ffmpeg"
exit 1
