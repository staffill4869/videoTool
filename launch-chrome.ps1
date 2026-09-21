# Flow 자동화용 Chrome 을 띄운다.
#
# 평소 쓰는 Chrome 을 그대로 쓰지 않고 전용 프로필을 쓰는 이유:
#   - 기본 프로필로 Chrome 이 이미 떠 있으면 --remote-debugging-port 가 무시된다
#     (새 창만 열리고 디버그 포트는 안 열린다). 그렇다고 평소 브라우저를 닫으라 할 수는 없다.
#   - 자동화가 평소 브라우징과 섞이지 않는다.
#
# 처음 한 번은 사람이 직접 구글 로그인을 해야 한다. 자동화는 로그인을 하지 않는다.
#
# 기본은 **화면 밖**에 띄운다(모니터 왼쪽 바깥 좌표). 최소화하면 안 된다 — 최소화된 창은
# Chrome 이 그리기를 멈춰서 호버·스크린샷이 먹통이 된다(스크린샷 30초 타임아웃 실측).
# 화면에서 보고 싶을 때는 **닫지 말고** `.\show-chrome.ps1` 로 창을 화면 안으로 끌어온다
# (생성 중에도 안전하다). 숨길 때는 `.\show-chrome.ps1 -Hide`.
# 처음부터 보이게 띄우려면 `.\launch-chrome.ps1 -Show`.

param([switch]$Show)

$port    = 9222
# 프로필 경로를 하드코딩하지 않는다. 폴더 이름이 바뀌면 없는 경로로 Chrome 이 떠서
# 로그인 없는 새 프로필이 만들어진다 — 실제로 그렇게 프로필이 둘로 갈렸다.
$profile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) ".chrome-profile"
$chrome  = "C:\Program Files\Google\Chrome\Application\chrome.exe"
$flowUrl = "https://flow.google.com/"

if (-not (Test-Path $chrome)) { Write-Host "Chrome 을 찾을 수 없습니다: $chrome"; exit 1 }

$alive = Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue
if ($alive) {
  Write-Host "이미 떠 있습니다 (포트 $port, PID $($alive[0].OwningProcess))"
  exit 0
}

New-Item -ItemType Directory -Force -Path $profile | Out-Null

$chromeArgs = @(
  "--remote-debugging-port=$port",
  "--user-data-dir=`"$profile`"",
  "--no-first-run",
  "--no-default-browser-check",
  # 가려지거나 화면 밖에 있어도 느려지지 않게 한다. 이게 없으면 다른 창에 덮인 것만으로
  # 타이머·렌더링이 늦춰져 대기·호버가 어긋난다.
  "--disable-backgrounding-occluded-windows",
  "--disable-renderer-backgrounding",
  "--disable-background-timer-throttling"
)
if (-not $Show) { $chromeArgs += @("--window-position=-3000,0", "--window-size=1920,1080") }

Start-Process -FilePath $chrome -ArgumentList ($chromeArgs + $flowUrl)

# 프로필 시작 페이지(zum 같은 포털)가 같이 뜨면 **닫는다.** 광고 iframe 을 십수 개 끌고 와서
# Playwright 가 붙을 때 전부 따라 붙느라 연결이 늦어지고, 드라이버가 그걸 "걸렸다" 고 보고
# 청소하다가 Chrome 을 통째로 죽였다(2026-09-18, iframe 16개 중 14개가 zum 광고였다).
# 탭 하나만 닫는 /json/close 라 브라우저는 건드리지 않는다.
Start-Sleep -Seconds 4
try {
  $tabs = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -TimeoutSec 5
  foreach ($t in $tabs) {
    if ($t.type -eq "page" -and $t.url -notlike "*flow.google.com*" -and $t.url -notlike "*accounts.google.com*") {
      Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/close/$($t.id)" -TimeoutSec 5 | Out-Null
      Write-Host "딸려 온 탭을 닫았습니다: $($t.url)"
    }
  }
} catch {
  # 못 닫아도 Chrome 은 떠 있다. 여기서 실패시키지 않는다.
}

Write-Host "Chrome 을 띄웠습니다 (포트 $port, 프로필 $profile)"
if (-not $Show) { Write-Host "화면 밖에 띄웠습니다. 보려면 .\show-chrome.ps1 (닫을 필요 없습니다)." }
Write-Host ""
Write-Host "처음이라면 이 창에서 직접 구글 로그인을 하세요. 자동화는 로그인을 대신하지 않습니다."
Write-Host "다운로드가 '저장 위치 묻기' 로 설정돼 있으면 꺼주세요 — 자동 수집이 안 됩니다."