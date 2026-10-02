#!/usr/bin/env bash
# 무인 제작 루프 (리눅스). run-agent.ps1 의 이식본.
#
# 서버는 프로젝트를 만들고 Flow 단계까지 스스로 민다. 하지만 대본·장면·허용수치는
# 말을 만드는 일이라 서버가 못 한다 — 서버에는 LLM 이 없다.
# 그 세 가지만 채우라고 헤드리스 에이전트를 주기마다 깨운다.
#
#   ./run-agent.sh              한 번 돌린다
#   ./run-agent.sh --dry-run    무슨 일이 있는지만 보고 에이전트는 안 깨운다
#   ./run-agent.sh --no-publish 합성까지만, 유튜브에 안 올린다
#   ROUNDS=10 TIMEOUT_SEC=2400 ./run-agent.sh
#
# systemd 타이머로 돌린다: videocrm-agent.timer

set -uo pipefail

ROOT="${VIDEOCRM_ROOT:-$HOME/videoCRM}"
API="${VIDEOCRM_API:-http://127.0.0.1:4300}"   # localhost 로 쓰면 안 된다 — ::1 로 풀려 연결이 안 된다
LOGDIR="$ROOT/logs"
LOCK="$ROOT/.agent.lock"
ROUNDS="${ROUNDS:-10}"
TIMEOUT_SEC="${TIMEOUT_SEC:-2400}"   # 한 라운드에 CLEAN→INFO→VIDEO 를 다 미는 걸 봤다 — 15분은 짧다
DRY_RUN=0
NO_PUBLISH=0

for a in "$@"; do
  case "$a" in
    --dry-run)    DRY_RUN=1 ;;
    --no-publish) NO_PUBLISH=1 ;;
    *) echo "모르는 인자: $a"; exit 2 ;;
  esac
done

mkdir -p "$LOGDIR"
LOG="$LOGDIR/agent-$(date +%Y-%m-%d).log"

# claude 자격증명. 600 파일에만 둔다 — 저장소에 넣지 않는다.
# 없으면 에이전트가 "Not logged in" 한 줄 남기고 매 라운드 그냥 끝난다(진척 0 으로 보인다).
AGENT_ENV="${AGENT_ENV:-$HOME/.videocrm-agent.env}"
if [ -f "$AGENT_ENV" ]; then
  set -a; . "$AGENT_ENV"; set +a
fi

say() {
  local line="[$(date +%H:%M:%S)] $*"
  echo "$line"
  # 기록은 부수적인 일이다. 로그를 못 써도 실행은 계속한다.
  echo "$line" >> "$LOG" 2>/dev/null || true
}

api_post() {  # api_post <툴> <json>
  curl -s -m "${3:-30}" -X POST "$API/api/tools/$1" \
       -H "Content-Type: application/json" -d "$2" 2>/dev/null
}

# ── 겹쳐 돌지 않기 ─────────────────────────────────────────────
# 둘이 동시에 next_job 을 집으면 같은 프로젝트에 대본을 두 번 쓴다.
if [ -f "$LOCK" ]; then
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$LOCK") ) / 60 ))
  if [ "$age_min" -lt 60 ]; then
    say "이전 실행이 아직 돌고 있습니다 (${age_min}분째). 건너뜁니다."
    exit 0
  fi
  say "오래된 잠금 파일을 치웁니다 (${age_min}분)."
  rm -f "$LOCK"
fi

# ── 에이전트가 인증돼 있어야 한다 ───────────────────────────────
# 이걸 안 보면 로그인이 풀렸을 때 라운드마다 "Not logged in" 만 남기고
# 진척 0 으로 두 번 돌다 조용히 멈춘다 — 원인을 찾는 데 한참 걸린다.
#
# 순서: 파일(.videocrm-agent.env) → 화면(/settings 에 넣은 값).
# 화면 쪽을 둔 이유는 토큰이 1년마다 바뀌는데, 그때마다 서버에 SSH 로 들어가야 하면
# 키 있는 사람만 갱신할 수 있기 때문이다.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
  FROM_UI=$(curl -s -m 20 "$API/api/settings/claude_token" 2>/dev/null \
    | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('value') or '')
except Exception: print('')
" 2>/dev/null)
  if [ -n "$FROM_UI" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="$FROM_UI"
    say "claude 토큰: 화면(/settings)에 넣은 값을 씁니다"
  fi
fi

if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
  say "claude 자격증명이 없습니다."
  say "  화면: $API/settings 의 'Claude 에이전트 토큰' 칸"
  say "  또는: $AGENT_ENV 에 CLAUDE_CODE_OAUTH_TOKEN"
  say "  (만드는 법: 아무 PC 에서 claude setup-token)"
  exit 1
fi

# ── 서버가 떠 있어야 한다 ───────────────────────────────────────
SUMMARY=$(curl -s -m 15 "$API/api/work/summary" 2>/dev/null)
if [ -z "$SUMMARY" ]; then
  say "서버에 붙지 못했습니다 ($API). sudo systemctl status videocrm 으로 보세요."
  exit 1
fi

# ── 크롬이 살아 있어야 한다 ─────────────────────────────────────
# Flow 는 Chrome 하나를 물고 돈다. CDP 가 죽으면 그 시점부터 전 단계가 멈추는데
# 조용히 멈춰서 알아채기까지 오래 걸린다. 깨어날 때마다 본다.
if curl -s -m 5 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
  say "Chrome(9222) 정상"
else
  say "Chrome(9222) 응답 없음 — 다시 띄웁니다"
  sudo systemctl restart flow-chrome 2>/dev/null || systemctl --user restart flow-chrome 2>/dev/null
  for _ in $(seq 1 30); do
    curl -s -m 3 http://127.0.0.1:9222/json/version >/dev/null 2>&1 && break
    sleep 2
  done
  curl -s -m 3 http://127.0.0.1:9222/json/version >/dev/null 2>&1 \
    || { say "크롬을 못 살렸습니다. 로그인이 풀렸을 수도 있습니다 — noVNC 로 보세요."; exit 1; }
fi

PENDING=$(echo "$SUMMARY" | python3 -c "import json,sys;print(int(json.load(sys.stdin)['summary'].get('pending_jobs',0)))" 2>/dev/null || echo 0)
PROJECTS=$(echo "$SUMMARY" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary'].get('projects',0))" 2>/dev/null || echo 0)
SERIES=$(echo "$SUMMARY" | python3 -c "import json,sys;print(json.load(sys.stdin)['summary'].get('active_series',0))" 2>/dev/null || echo 0)

# pending_jobs 는 **대본 쪽 일만** 센다. 에이전트가 하는 일은 그보다 넓다 —
# CLEAN·INFO·VIDEO·합성·발행이 남아 있어도 pending 은 0 이라, 이것만 보고 끝내면
# 할 일이 산더미인데 "할 일이 없습니다" 하고 나간다(실측).
UNFINISHED=$(api_post list_projects '{"unfinished_only":true}' 20 \
  | python3 -c "import json,sys;print(int(json.load(sys.stdin).get('count',0)))" 2>/dev/null || echo 0)

say "대기 $PENDING 건 / 미완료 $UNFINISHED 건 / 프로젝트 $PROJECTS개 / 도는 시리즈 $SERIES개"

if [ "$PENDING" -le 0 ] && [ "$UNFINISHED" -le 0 ]; then
  say "에이전트가 할 일이 없습니다. 끝냅니다."
  exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "DryRun — 에이전트를 깨우지 않고 끝냅니다."
  exit 0
fi

# ── 진척 지표 ──────────────────────────────────────────────────
# 모든 프로젝트의 자산(clean+info+clip) + 완성본 총합. 이 숫자가 늘었으면 뭔가 만들어진 것이다.
# 조회 실패는 -1 로 돌려 '모른다' 와 '제자리' 를 구분한다 — 모르면 멈추지 않는다.
get_progress() {
  api_post list_projects '{}' 30 | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(sum(int(p.get('clean',0))+int(p.get('info',0))+int(p.get('clip',0))+int(p.get('renders',0))
              for p in d.get('projects',[])))
except Exception:
    print(-1)
" 2>/dev/null || echo -1
}

# ── Flow 가 끝나기를 기다린다 ──────────────────────────────────
# **에이전트 대신 여기서 기다린다.** claude --print 는 한 턴만 돌고 끝나는 모드라,
# 몇 분짜리 생성 앞에서 모델은 "기다리는 중" 한 줄을 남기고 턴을 닫는다.
# 모델이 기다리게 만들려고 싸우지 말고 바깥에서 기다렸다가 다시 깨운다.
wait_flow_idle() {
  local max="${1:-1500}" t0 st
  t0=$(date +%s)
  while [ $(( $(date +%s) - t0 )) -lt "$max" ]; do
    st=$(api_post flow_job '{}' 20 | python3 -c "import json,sys;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    [ -z "$st" ] && return 0            # 조회가 안 되면 기다릴 근거도 없다
    [ "$st" != "running" ] && return 0
    sleep 20
  done
  say "Flow 작업이 ${max}초를 넘겨도 안 끝납니다"
  return 1
}

PROMPT_FILE="$(mktemp)"

# 지시문은 **화면(/prompts 의 agent 탭)에서 고친 것**을 먼저 쓴다.
# 없거나 비어 있으면 아래에 박아둔 기본값으로 떨어진다 — 화면에서 실수로 비워도
# 루프가 멈추지 않게 한다. 짧으면(=실수로 지운 것으로 본다) 기본값을 쓴다.
DB_PROMPT=$(api_post get_prompt_template '{"stage":"agent"}' 20 \
  | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    t = d.get('body') or ''
    # 너무 짧으면 실수로 지운 것으로 보고 기본값을 쓴다
    print(t if len(t) > 400 else '')
except Exception:
    print('')
" 2>/dev/null)

if [ -n "$DB_PROMPT" ]; then
  printf '%s\n' "$DB_PROMPT" > "$PROMPT_FILE"
  say "지시문: 화면에서 고친 것을 씁니다 (${#DB_PROMPT}자)"
else
  say "지시문: 기본값을 씁니다 (화면에 저장된 것이 없거나 너무 짧습니다)"
  cat > "$PROMPT_FILE" <<'PROMPT'
videoTool MCP 서버(videotool 또는 videocrm)에 붙어서 영상을 끝까지 만들고 올린다.
사람에게 묻지 마라. 막히면 무엇이 막혔는지 한 줄 적고 끝내라.

**한 편을 만들어 올리고, 곧바로 다음 편을 만들어 올린다. 시간이 다 될 때까지 반복한다.**

이번에 할 편을 이렇게 고른다:
  a. list_projects 로 보고, 만들다 만 것(완성본 없음)이 있으면 **그것부터 끝낸다**
  b. 없으면 list_series 로 시리즈를 보고 run_series 로 새 편을 만들고 [1]부터 시작한다
     ↳ run_series 는 **topic(이번 편 주제)을 반드시 받는다.** 아래 규칙을 먼저 읽어라
  c. 완성본은 있는데 발행만 안 된 편은 [8] 만 하면 된다 — 1분이면 끝나니 먼저 치운다

한 편을 [1]~[8] 까지 끝낸 뒤 a 로 돌아간다. 이걸 계속 반복한다.
여러 편을 동시에 밀지 마라 — Flow 는 브라우저 하나를 쓴다.
새 편 주제 고르기 — **여기서 실수하면 같은 영상이 또 올라간다** (2026-09-23 에 네 편이 그랬다):
  1. list_series 응답의 `recent` 를 본다. 그 시리즈에서 이미 만든 제목·주제가 전부 들어 있다.
     (list_projects 로는 안 보인다 — 거기는 아직 안 끝난 편만 내준다)
  2. recent 에 있는 것과 **다른** 주제를 하나 고른다. 시리즈 성격에는 맞아야 한다.
  3. run_series(series_id, topic: "고른 주제") 로 부른다.
     **시리즈 설명문을 topic 으로 넣지 마라.** 그건 시리즈 전체의 소개지 이번 편 주제가 아니다.
     좋은 예: `고양이는 왜 꾹꾹이를 할까` · `밤에 갑자기 뛰어다니는 이유(나이트 줌이)`
     나쁜 예: `고양이의 행동과 몸을 '왜 그런가' 로 푸는 시리즈`
  4. 거부당하면(`이미 만들었습니다`) 응답의 `already_made` 를 보고 **다른 주제로 다시** 부른다.
     같은 주제로 재시도하지 마라.

[1] 대본이 없는 프로젝트
    next_job 이 내주는 대로 save_script / save_scenes / save_allowed_facts 를 채운다.

    **장면 하나는 5.5초다.** (Flow 가 내주는 8초 클립을 1.45배속으로 밀어 넣는다 —
    화면은 빠르게 가고 대사는 그 5.5초에 맞춘다. 이게 지금 원하는 속도감이다.)
    - 한 장면 대사는 **공백 제외 26~28자**. target_sec 은 **5.5** 로 저장한다
    - estimate_length 는 project_id 가 아니라 **text 와 voice_slug** 를 받는다.
      거기서 나오는 chars 는 **공백을 뺀 수**다. 장면 8개면 목표는 **210~225자 / 42~45초**
    - 마지막 장면은 질문으로 끝낸다
    - 낭독 속도로 길이를 맞추지 마라. 안 맞으면 글자 수를 고친다
    - 날짜·수치는 **읽히는 음절**로 길이를 잡는다. "1995년 6월 29일" 은 12자지만 8.7초다.
      긴 숫자는 대사에서 빼고 expected_labels(화면 라벨) 로 넘긴다

    expected_labels — 화면 위쪽에 크게 뜨는 글자다. 규칙이 바뀌었다:
    - **장면당 하나만 쓴다.** 96pt 로 커져서 둘을 붙이면 줄이 넘친다 (첫 번째만 화면에 나간다)
    - **핵심 단어 하나 또는 수치 하나.** 문장으로 쓰지 마라
      좋은 예: `3,136 mg` · `WHO 2,000 mg` · `−34.5%` · `소금통 아님`
      나쁜 예: `한국인 하루 나트륨 섭취량은 3,136 mg 이다`
    - 숫자와 단위는 붙여서 한 덩어리로 (`800→600 mm`) — 줄바꿈으로 갈리면 수치가 죽는다
    - 외곽선 없는 흰 글자로 나간다. 배경이 밝은 장면에는 라벨을 넣지 마라

[2] CLEAN
    flow_generate(project_id, stage: "clean")
    flow_job 으로 done 이 될 때까지 기다린다(30초 간격). failed 여도 flow_harvest 로 회수해 본다.

[3] 장면 순서 확인  ← 절대 건너뛰지 마라
    contact_sheet(project_id, kind: "clean") 를 부르면 시트 파일 경로와
    칸마다 어느 장면 대사인지가 나온다. 그 파일을 Read 로 **직접 열어 보고**,
    칸의 그림이 그 장면 대사와 맞는지 하나씩 확인한다.
    어긋나면 remap_scenes(kind: "clean", order: [...]) 로 고친다.
    order 는 "1번 장면에 지금 몇 번 칸 그림을 쓸지" 의 나열이다. 예: [5,1,4,2,7,8,6,3]
    배정 신뢰도가 높아도 순서는 뒤섞여 있다. 실제로 만든 편마다 전부 고쳐야 했다.
    회수는 **파일 순서대로** 붙으므로, 같은 결과를 다시 회수하면 **똑같이 틀린다** —
    한 번 알아낸 order 는 그대로 다시 쓸 수 있다.

[4] INFO
    flow_generate(stage: "info") → 기다림 →
    contact_sheet(kind: "info") 로 다시 확인한다. INFO 는 라벨이 붙어 있어 판단이 쉽다.
    어긋나면 clean 과 info 를 **같은 order 로 함께** remap 한다. 둘은 짝이다.

[5] VIDEO  ← 한 번에 다 안 나온다. 다 찰 때까지 반복한다
    flow_generate(stage: "video") → 기다림 → flow_harvest(stage: "video")
    **Flow 는 일부를 "실패" 타일로 떨군다**(실측: 8개 중 3개. "동영상을 생성할 수 없습니다",
    "수요가 많습니다"). 실패분은 **크레딧이 청구되지 않으니** 다시 걸어도 된다.
    모자란 장면만 flow_generate(stage: "video", scene_nos: [빠진 번호들]) 로 다시 건다.
    3~4라운드가 걸릴 수 있다.
    클립이 모자라면 남는 클립이 **엉뚱한 장면에 중복으로** 붙는다(신뢰도가 낮게 나온다).
    한 장면에 2개가 붙었으면 contact_sheet(kind: "clip") 로 보고, 틀린 쪽을 지우지 말고
    **status 를 rejected 로** 둔다 — 합성이 알아서 건너뛴다.
    **drop_assets 를 쓰지 마라.** 그건 scene_nos 를 안 받고 그 단계를 **통째로** 지운다.

    **8/8 이 다 찰 때까지 [6] 으로 넘어가지 마라.**

[6] 나레이션  ← [5] 가 8/8 인 것을 확인한 뒤에만
    generate_narration(project_id) 하나면 된다. 일레븐랩스로 만들고 등록까지 한다.
    프로젝트 variables 에 eleven_voice_id 가 없으면 voice_id 인자로 넘긴다.
    **클립이 다 있기 전에 부르면 안 된다.** 이 툴은 **그때 클립이 붙어 있는 장면만**
    시간표(scene_timing)에 넣고, 그게 그대로 굳는다. 실측: 클립 6개일 때 불렀더니
    61초짜리가 **46.9초로 잘려** 나왔다. 뒤 13초가 통째로 날아간다.
    만든 뒤 응답의 scenes 가 **장면 수와 같은지 확인**한다. 다르면 클립을 마저 채우고 다시 부른다.

[7] 합성
    assemble(project_id)
    리타이밍·나레이션·자막·화면 라벨을 한 번에 한다. 2 vCPU 라 10분 안팎 걸린다.
    끝나면 **완성본 길이가 나레이션 길이와 비슷한지 본다.** 많이 짧으면 [6] 을 의심한다.
    이어서 check_video(project_id) 로 검사하고, 걸린 항목은 고친 뒤 [8] 로 간다.

[8] 발행
    save_publish_meta(project_id, channel_slug, title, description, hashtags) 로 메타를 넣고
    publish(project_id, channel_slug, confirm: true) 로 올린다.
    channel_slug 는 그 프로젝트가 속한 시리즈의 channel_slug 를 쓴다.
    공개 범위는 손대지 마라 — 채널 설정이 private 이면 서버가 무조건 private 으로 올린다.
    제목은 영상 내용 그대로, 낚시 금지. 설명 끝에 마지막 장면의 질문을 넣는다.

지켜야 할 것
- [3] 과 [4] 의 시트 확인을 건너뛰지 마라. 이걸 빼면 대사와 화면이 끝까지 어긋난다
- [5] 가 다 차기 전에 [6] 을 부르지 마라. 영상이 조용히 잘린다
- 한 번에 한 편만. 다른 편으로 넘어가기 전에 그 편을 끝낸다
- 화면 제어(마우스·키보드)를 쓰지 마라. MCP 도구와 위에 적힌 명령만 쓴다
- 크레딧이 나가는 일이다. 같은 단계를 이유 없이 두 번 돌리지 마라.
  다만 **실패 타일은 크레딧을 안 먹으니** 모자란 장면 재시도는 괜찮다

시간이 얼마 안 남았으면 새 편을 시작하지 말고, 만든 편과 올린 주소를 한 줄로 보고하고 종료해.
PROMPT
fi

# 시험 실행이면 발행을 막는다. 유튜브 업로드는 되돌릴 수 없어서 시험에 넣지 않는다.
if [ "$NO_PUBLISH" -eq 1 ]; then
  cat >> "$PROMPT_FILE" <<'EOF'

**이번 실행은 시험이다. [8] 발행을 하지 마라.**
[7] 합성과 check_video 까지만 하고, 만든 편의 id 와 완성본 경로를 한 줄로 보고해라.
한 편이 끝나면 **다음 편을 이어서 만든다** — 라운드가 남아 있는 한 계속한다.

**중요 — 발행만 남은 편은 건너뛰어라.** list_projects 의 "미완료" 에는
*완성본이 있는데 발행만 안 된 편*도 들어 있다(판정이 `renders == 0 or not published` 다).
발행을 막아 둔 이번 실행에서는 그런 편에 **할 일이 없다.** 집어 들면 할 게 없어서
렌더를 하염없이 기다리게 된다(실측 2026-09-23).
renders 가 0 이거나 clean·info·clip 이 장면 수보다 모자란 편만 골라라.
EOF
  say "시험 실행: 발행 없음, 한 편만"
fi

touch "$LOCK"
cleanup() { rm -f "$LOCK" "$PROMPT_FILE"; }
trap cleanup EXIT

STALE=0
for round in $(seq 1 "$ROUNDS"); do
  wait_flow_idle || break

  BEFORE=$(get_progress)
  OUT="$LOGDIR/run-$(date +%Y%m%d-%H%M%S).txt"
  say "라운드 $round/$ROUNDS — 에이전트를 깨웁니다 (최대 $TIMEOUT_SEC 초)"

  # --print: 대화창 없이 한 번 돌고 끝난다. 프롬프트는 stdin 으로 넘긴다 —
  # 인자로 넘기면 길이와 인용 처리에서 깨진다.
  ( cd "$ROOT" && timeout "$TIMEOUT_SEC" \
      claude --print --permission-mode acceptEdits < "$PROMPT_FILE" \
      > "$OUT" 2> "$OUT.err" )
  rc=$?
  [ "$rc" -eq 124 ] && say "시간 초과 — 에이전트를 종료했습니다"

  tail -n 3 "$OUT" 2>/dev/null | while IFS= read -r l; do say "  > $l"; done

  # 진척이 있었나 — **자산과 완성본의 총 개수**로 본다.
  # pending_jobs 로 재면 안 된다. 그건 대본 쪽 일만 세서, 한 라운드에 자산 32개를
  # 만들어 놓고도 "제자리" 가 나온다 (실측 2026-09-23).
  AFTER=$(get_progress)
  MOVED=0
  { [ "$AFTER" -lt 0 ] || [ "$BEFORE" -lt 0 ] || [ "$AFTER" -gt "$BEFORE" ]; } && MOVED=1
  if [ "$MOVED" -eq 0 ]; then
    st=$(api_post flow_job '{}' 20 | python3 -c "import json,sys;print(json.load(sys.stdin).get('state',''))" 2>/dev/null)
    [ "$st" = "running" ] && MOVED=1   # 걸어놓고 나간 것도 진척이다
  fi
  say "  진척: 자산+완성본 $BEFORE -> $AFTER"

  if [ "$MOVED" -eq 1 ]; then
    STALE=0
  else
    STALE=$((STALE+1))
    say "이 라운드에서 진척이 없습니다 ($STALE/2)"
    [ "$STALE" -ge 2 ] && { say "두 번 연속 제자리 — 멈춥니다"; break; }
  fi
done

# 처리 뒤 남은 일을 다시 본다. 줄지 않았으면 뭔가 막힌 것이다.
AFTER_PENDING=$(curl -s -m 15 "$API/api/work/summary" 2>/dev/null \
  | python3 -c "import json,sys;print(int(json.load(sys.stdin)['summary'].get('pending_jobs',0)))" 2>/dev/null || echo -1)
say "끝난 뒤 대기 ${AFTER_PENDING}건 (시작 $PENDING 건)"
if [ "$AFTER_PENDING" -ge 0 ] && [ "$AFTER_PENDING" -ge "$PENDING" ]; then
  say "줄지 않았습니다. $LOGDIR 의 최근 run-*.txt 를 확인하세요."
fi
