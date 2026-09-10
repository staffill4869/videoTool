# videoCRM 서버 재시작.
#
# 포트 4300 리스너 PID 만 죽인다. Get-Process erl | Stop-Process 를 절대 쓰지 말 것 —
# 4000/4200 등 다른 프로젝트의 Phoenix 서버까지 같이 죽는다.

$port = 4300
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$mix  = "C:\Users\pract\scoop\apps\elixir\current\bin\mix.bat"

Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty OwningProcess -Unique |
  ForEach-Object {
    Write-Host "기존 서버 종료: PID $_"
    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
  }

Start-Sleep -Seconds 2

Start-Process -FilePath $mix -ArgumentList "phx.server" -WorkingDirectory $root `
  -RedirectStandardOutput (Join-Path $root "server.log") `
  -RedirectStandardError  (Join-Path $root "server.err.log") `
  -WindowStyle Hidden

Write-Host "기동 대기..."
foreach ($i in 1..30) {
  Start-Sleep -Seconds 2
  $listener = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
  if ($listener) {
    Write-Host "http://localhost:$port  (PID $($listener[0].OwningProcess))"
    Write-Host "MCP:      http://localhost:$port/mcp"
    Write-Host "Tidewave: http://localhost:$port/tidewave/mcp"
    exit 0
  }
}

Write-Host "기동 실패. server.log 를 확인하세요."
exit 1