#!/usr/bin/env bash
# Flow 자동화용 Chrome 을 띄운다 (리눅스판). 원본: launch-chrome.ps1
#
# 윈도우판과 가장 크게 다른 점: 서버에는 화면이 없다. 그래서 Xvfb 로 가짜 X 디스플레이를
# 하나 만들고, 그 안에 **진짜 headed google-chrome-stable** 을 띄운다.
#
# --headless 는 절대 쓰지 않는다. 구글 로그인이 헤드리스를 알아보고 17초 만에 튕긴다.
# 배포판 chromium(snap/apt) 도 대체가 안 된다 — 코덱과 UA 가 달라 Flow 가 다르게 동작한다.
#
# 전용 프로필(--user-data-dir)은 선택이 아니라 필수다.
#   크롬 136+ 는 **기본 프로필에서 --remote-debugging-port 를 조용히 무시한다.**
#   에러도 안 나고 크롬은 멀쩡히 뜨는데 9222 만 안 열려서, 자동화가 빈 페이지에서
#   영원히 기다린다. 원인을 찾는 데 제일 오래 걸리는 종류의 고장이다.
#
# 봇 탐지 쪽:
#   --disable-blink-features=AutomationControlled 를 넣고 --enable-automation 은 안 넣는다.
#   (navigator.webdriver 가 true 로 서면 구글 로그인이 막힌다. 띄운 뒤 undefined/false 확인)
#
# --window-position 은 뺐다. 윈도우판은 창을 화면 밖(-3000,0)으로 밀었지만,
# Xvfb 안에서는 이미 아무도 안 보고 있고, 화면 밖으로 밀면 크롬이 그리기를 멈춰
# 호버·스크린샷이 먹통이 된다. 여기서는 밀 이유가 없다.
#
# 9222 는 **127.0.0.1 에만** 연다(--remote-debugging-address). 이 포트가 밖으로 열리면
# 로그인된 구글 세션이 통째로 털린다. 인증이 전혀 없는 포트다.
#
# 처음 한 번은 사람이 직접 구글 로그인을 해야 한다. 자동화는 로그인을 하지 않는다.
# 윈도우 프로필을 복사해 오는 건 확정적으로 실패한다(쿠키가 DPAPI+App-Bound 로 그 PC 에 묶여 있다).
# 화면을 보려면 x11vnc + websockify 를 이 디스플레이에 붙인다:
#   x11vnc -display :98 -localhost -nopw -forever &
#   websockify 6080 127.0.0.1:5900 &
#   ssh -L 6080:127.0.0.1:6080 서버   → 브라우저에서 http://127.0.0.1:6080/vnc.html
#   로그인이 끝나면 둘 다 끈다.
#
#   ./launch-chrome.sh           # 안 떠 있으면 띄운다 (떠 있으면 아무것도 안 한다)
#   ./launch-chrome.sh --restart # 떠 있어도 죽이고 다시 띄운다

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 앱 루트. 프로필을 앱 옆(.chrome-profile)에 두는 건 윈도우판과 같다.
ROOT="${VIDEOCRM_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

PORT="${FLOW_CDP_PORT:-9222}"
DISP="${FLOW_DISPLAY:-:98}"
# 프로필 경로를 하드코딩하지 않는다. 폴더 이름이 바뀌면 없는 경로로 크롬이 떠서
# 로그인 없는 새 프로필이 만들어진다 — 윈도우에서 실제로 그렇게 프로필이 둘로 갈렸다.
PROFILE="${FLOW_CHROME_PROFILE:-$ROOT/.chrome-profile}"
CHROME="${FLOW_CHROME_BIN:-google-chrome-stable}"
FLOW_URL="https://flow.google.com/"
CHROME_LOG="${FLOW_CHROME_LOG:-$ROOT/logs/chrome.log}"

RESTART=0
[[ "${1:-}" == "--restart" ]] && RESTART=1

command -v "$CHROME" >/dev/null 2>&1 || { echo "Chrome 을 찾을 수 없습니다: $CHROME"; exit 1; }
command -v Xvfb     >/dev/null 2>&1 || { echo "Xvfb 가 없습니다: apt install xvfb xauth"; exit 1; }

# root 로 돌리면 --no-sandbox 를 쓸 수밖에 없다. 전용 유저로 돌린다.
[[ "$(id -u)" == "0" ]] && echo "경고: root 로 돌고 있습니다. 전용 유저로 돌리세요 (--no-sandbox 를 피하려면)."

alive() { curl -sS --max-time 5 "http://127.0.0.1:$PORT/json/version" >/dev/null 2>&1; }

if alive; then
  if [[ $RESTART -eq 0 ]]; then
    echo "이미 떠 있습니다 (포트 $PORT)"
    exit 0
  fi
  echo "이미 떠 있지만 --restart 라 다시 띄웁니다"
fi

# 이 프로필을 물고 있는 크롬만 골라 죽인다.
# pkill chrome 같은 넓은 패턴은 금지 — 같은 서버의 다른 크롬까지 죽는다.
pkill -f -- "--user-data-dir=$PROFILE" 2>/dev/null || true
sleep 2

mkdir -p "$PROFILE" "$(dirname "$CHROME_LOG")"

# 크롬이 비정상 종료하면 SingletonLock 이 남아, 다음 기동에서 크롬이
# "이미 떠 있다" 며 조용히 기존 인스턴스에 붙으려다 아무것도 안 뜬다.
# systemd 에서 ExecStartPre 로도 같은 일을 한다. 재시작 때마다 지운다.
rm -f "$PROFILE/SingletonLock" "$PROFILE/SingletonSocket" "$PROFILE/SingletonCookie"

# Xvfb 가 이미 돌고 있으면 다시 띄우지 않는다.
# 판단은 락 파일로 한다 — xdpyinfo(x11-utils)를 추가로 깔지 않아도 된다.
if [[ ! -e "/tmp/.X${DISP#:}-lock" ]]; then
  echo "Xvfb $DISP 를 띄웁니다"
  # -noreset: 마지막 클라이언트가 죽어도 X 서버가 리셋되지 않는다. 리셋되면 크롬이 같이 죽는다.
  Xvfb "$DISP" -screen 0 1920x1080x24 -ac -noreset >/dev/null 2>&1 &
  sleep 2
fi

# 도커 안이면 /dev/shm 이 64MB 라 크롬이 탭째로 죽는다.
# 그때는 --disable-dev-shm-usage 대신 **shm_size: 2g** 로 고친다
# (플래그를 쓰면 /tmp 로 떨어져서 느려진다).
CHROME_ARGS=(
  "--remote-debugging-port=$PORT"
  # 9222 를 루프백에만 연다. 이게 없으면 0.0.0.0 으로 열려 세션이 통째로 노출된다.
  "--remote-debugging-address=127.0.0.1"
  "--user-data-dir=$PROFILE"
  "--no-first-run"
  "--no-default-browser-check"
  # navigator.webdriver 를 세우지 않는다. --enable-automation 은 절대 넣지 않는다.
  "--disable-blink-features=AutomationControlled"
  # 가려지거나 포커스가 없어도 느려지지 않게 한다. 이게 없으면 타이머·렌더링이 늦춰져
  # 대기·호버가 어긋난다. Xvfb 안에서는 항상 포커스가 없는 상태에 가깝다.
  "--disable-backgrounding-occluded-windows"
  "--disable-renderer-backgrounding"
  "--disable-background-timer-throttling"
  "--window-size=1920,1080"
)

# setsid: 이 스크립트(또는 cron/systemd oneshot)가 끝나도 크롬은 살아 있어야 한다.
DISPLAY="$DISP" setsid "$CHROME" "${CHROME_ARGS[@]}" "$FLOW_URL" >>"$CHROME_LOG" 2>&1 &
disown || true

# 9222 가 열릴 때까지 기다린다. 안 열리면 위의 "조용히 무시" 증상이므로 바로 알린다.
for _ in $(seq 1 20); do
  alive && break
  sleep 1
done
if ! alive; then
  echo "9222 가 안 열렸습니다. $CHROME_LOG 를 보세요."
  echo "  (기본 프로필을 쓰면 크롬이 --remote-debugging-port 를 조용히 무시합니다 — 전용 프로필인지 확인)"
  exit 1
fi

# 프로필 시작 페이지(포털 등)가 같이 뜨면 닫는다. 광고 iframe 을 십수 개 끌고 와서
# Playwright 가 붙을 때 전부 따라 붙느라 연결이 늦어지고, 드라이버가 그걸 "걸렸다" 고 보고
# 청소하다가 크롬을 통째로 죽였다(2026-09-18, iframe 16개 중 14개가 광고였다).
# /json/close 는 탭 하나만 닫는다 — 브라우저는 안 건드린다.
# 여기서 실패해도 크롬은 떠 있다. 부수적인 일이라 본 작업을 죽이지 않는다.
if command -v jq >/dev/null 2>&1; then
  {
    curl -sS --max-time 5 "http://127.0.0.1:$PORT/json/list" \
      | jq -r '.[] | select(.type=="page")
               | select((.url | test("flow\.google\.com|accounts\.google\.com")) | not)
               | "\(.id)\t\(.url)"' \
      | while IFS=$'\t' read -r tid turl; do
          curl -sS --max-time 5 "http://127.0.0.1:$PORT/json/close/$tid" >/dev/null 2>&1 \
            && echo "딸려 온 탭을 닫았습니다: $turl"
        done
  } || true
fi

echo "Chrome 을 띄웠습니다 (디스플레이 $DISP, 포트 $PORT, 프로필 $PROFILE)"
echo ""
echo "처음이라면 VNC 로 이 화면에 들어가 직접 구글 로그인을 하세요. 자동화는 로그인을 대신하지 않습니다."
echo "  x11vnc -display $DISP -localhost -nopw -forever &"
echo "  websockify 6080 127.0.0.1:5900 &   →  ssh -L 6080:127.0.0.1:6080 로 터널"
echo "로그인 뒤 navigator.webdriver 가 undefined/false 인지, flow_status 가 ready 인지 확인하세요."
echo "다운로드가 '저장 위치 묻기' 로 설정돼 있으면 꺼주세요 — 자동 수집이 안 됩니다."
