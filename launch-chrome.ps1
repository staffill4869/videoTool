# Flow 자동화용 Chrome 을 띄운다.
#
# 평소 쓰는 Chrome 을 그대로 쓰지 않고 전용 프로필을 쓰는 이유:
#   - 기본 프로필로 Chrome 이 이미 떠 있으면 --remote-debugging-port 가 무시된다
#     (새 창만 열리고 디버그 포트는 안 열린다). 그렇다고 평소 브라우저를 닫으라 할 수는 없다.
#   - 자동화가 평소 브라우징과 섞이지 않는다.
#
# 처음 한 번은 사람이 직접 구글 로그인을 해야 한다. 자동화는 로그인을 하지 않는다.

$port    = 9222
$profile = "C:\rebase\videoCRM\.chrome-profile"
$chrome  = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$flowUrl = "https://labs.google/fx/ko/tools/flow"

if (-not (Test-Path $chrome)) { Write-Host "Chrome 을 찾을 수 없습니다: $chrome"; exit 1 }

$alive = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($alive) {
  Write-Host "이미 떠 있습니다 (포트 $port, PID $($alive[0].OwningProcess))"
  exit 0
}

New-Item -ItemType Directory -Force -Path $profile | Out-Null

Start-Process -FilePath $chrome -ArgumentList @(
  "--remote-debugging-port=$port",
  "--user-data-dir=`"$profile`"",
  "--no-first-run",
  "--no-default-browser-check",
  $flowUrl
)

Write-Host "Chrome 을 띄웠습니다 (포트 $port, 프로필 $profile)"
Write-Host ""
Write-Host "처음이라면 이 창에서 직접 구글 로그인을 하세요. 자동화는 로그인을 대신하지 않습니다."
Write-Host "다운로드가 '저장 위치 묻기' 로 설정돼 있으면 꺼주세요 — 자동 수집이 안 됩니다."