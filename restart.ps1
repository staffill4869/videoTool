# videoTool 서버 재시작.
#
# 포트 4300 리스너 PID 만 죽인다. Get-Process erl | Stop-Process 를 절대 쓰지 말 것 —
# 4000/4200 등 다른 프로젝트의 Phoenix 서버까지 같이 죽는다.
#
# 돌고 있는 Flow 작업이 있으면 멈춘다. 서버가 뜰 때 "끊긴 작업 청소" 가 돌아
# **멀쩡히 생성 중이던 작업을 실패로 찍기** 때문이다. 실제로 VIDEO 8장면을 15분째
# 만들던 job 105 를 재시작 한 번으로 날렸다 — 에이전트는 실패로 보고 처음부터
# 다시 만든다(크레딧 낭비). 정말 지금 꺼야 하면 -Force.

param([switch]$Force)

$port = 4300
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$mix  = "C:\Users\pract\scoop\apps\elixir\current\bin\mix.bat"

if (-not $Force) {
  try {
    $busy = Invoke-RestMethod -Uri "http://localhost:$port/api/tools/flow_status" `
      -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 5
    if ($busy.running_jobs -gt 0) {
      Write-Host "Flow 작업이 $($busy.running_jobs) 건 돌고 있습니다. 재시작하면 실패로 찍힙니다."
      Write-Host "기다리거나, 정말 지금 꺼야 하면:  .\restart.ps1 -Force"
      exit 2
    }
  } catch {
    # 서버가 이미 죽었거나 응답이 없으면 그냥 재시작한다.
  }
}

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