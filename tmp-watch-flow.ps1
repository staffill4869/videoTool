# Temporary watcher: poll flow_job every 60s, print only on change, exit when terminal.
# ASCII only on purpose - PowerShell 5.1 reads BOM-less files as ANSI.
param(
  [int]$ProjectId = 0,
  [int]$MaxPolls  = 25,
  [string]$Api    = "http://127.0.0.1:4300"   # not localhost: resolves to ::1 and hangs
)

$prev = ""
for ($i = 0; $i -lt $MaxPolls; $i++) {
  try {
    $r = Invoke-RestMethod -Uri "$Api/api/tools/flow_job" -Method Post `
           -Body (@{ project_id = $ProjectId } | ConvertTo-Json -Compress) `
           -ContentType "application/json" -TimeoutSec 30
  } catch {
    Write-Output ("poll error: " + $_.Exception.Message)
    Start-Sleep -Seconds 60
    continue
  }

  $state = "$($r.state)"
  $cur   = "state=$state harvested=$($r.harvested) error=$($r.error)"
  if ($cur -ne $prev) { Write-Output ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $cur); $prev = $cur }

  # Cover every terminal state, not just the happy path - silence must not look like progress.
  if ($state -match "done|failed|error|cancel") { Write-Output "TERMINAL $state"; exit 0 }
  Start-Sleep -Seconds 60
}
Write-Output "WATCH TIMEOUT after $MaxPolls polls: $prev"
