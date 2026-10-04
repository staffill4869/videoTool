#!/bin/bash
# videoCRM 무인 생산 워커.
#
# 백로그에 쌓인 프로젝트를 **하나씩** 끝까지 민다. Flow 는 창이 하나라
# 둘이 동시에 들어가면 서로 깨진다 — 그래서 이 스크립트는 **한 번에 하나**만 돌리고,
# 앱 쪽에도 전역 자물쇠(pg_advisory_xact_lock)가 걸려 있다.
#
# 영상은 **한 장면씩** 넣는다. 묶어 넣으면 Flow 에이전트가 생성 건마다 크레딧 승인을
# 묻는데 드라이버는 승인을 한 번만 눌러, 첫 건 뒤로 전부 멈춰 0개로 끝난다
# (실측 2026-10-02: 5~7장면 묶음 0개 / 1장면 1개).
#
# 발행은 하지 않는다. 만들어 두기만 한다.
set -u
# asdf 를 켠다 — systemd 는 로그인 셸이 아니라 PATH 에 mix 가 없다.
. "$HOME/.asdf/asdf.sh"
API=http://127.0.0.1:4300/api/tools
ROOT=/home/ec2-user/videoCRM
LOG=$ROOT/logs/worker.log
mkdir -p "$ROOT/logs"

say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

# 오늘 만든 편 수. **만드는 속도가 내보내는 속도의 3~4배라 상한이 없으면 디스크가 찬다.**
# 발행은 채널당 하루 3편(두 채널이면 6편)인데 생산은 하루 16~24편이 가능했다.
# 그 차이가 이틀 만에 서버를 멈춰 세웠다 (2026-10-04).
BUILT=$ROOT/ops/built.log
DAILY_BUILD_CAP=${DAILY_BUILD_CAP:-6}
mkdir -p "$ROOT/ops"; touch "$BUILT"

built_today() { grep -c "^$(date -u +%F) " "$BUILT" 2>/dev/null || echo 0; }
mark_built() { echo "$(date -u +'%F %T') $1" >> "$BUILT"; }

# 디스크가 얼마 안 남았으면 아예 시작하지 않는다. 꽉 찬 뒤에 멈추면 이미 늦다.
disk_free_gb() { df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9'; }
MIN_FREE_GB=${MIN_FREE_GB:-10}
call() { curl -s --max-time 900 -X POST "$API/$1" -H 'content-type: application/json' -d "$2"; }
jget() { python3 -c "import json,sys
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')" 2>/dev/null; }

wait_idle() {
  for _ in $(seq 1 180); do
    [ "$(call flow_job '{}' | jget state)" = "idle" ] && return 0
    sleep 20
  done
  return 1
}

# 단계별로 아직 자산이 없는 장면 번호. **떠 있는 앱에 묻는다.**
#
# 예전에는 scene_nos / stage_missing / missing 이 각각 `mix run` 이었다. 그건 컴파일 확인 +
# Phoenix 앱 전체 부팅이라 한 번에 20~30초씩 CPU 를 먹는다. 편마다 네다섯 번, 20편이면
# 백 번 가까이 앱을 새로 띄운 셈이고, 그게 2코어 서버를 멈춰 세웠다 (2026-10-04).
# 앱은 이미 4300 에 떠 있다. 물어보면 될 것을 새로 띄워서 물었다.
gaps() { call scene_gaps "{\"project_id\":$1}"; }
gap_of() { echo "$1" | python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: raise SystemExit
print(' '.join(str(n) for n in d.get('$2', [])))" 2>/dev/null; }




build() {
  local P=$1

  local n; n=$(built_today)
  if [ "$n" -ge "$DAILY_BUILD_CAP" ]; then
    say "오늘 $n 편을 만들어 상한($DAILY_BUILD_CAP)에 닿았습니다. 남은 편은 내일 만듭니다."
    return 2
  fi

  local gb; gb=$(disk_free_gb)
  if [ -n "$gb" ] && [ "$gb" -lt "$MIN_FREE_GB" ]; then
    say "디스크 여유 ${gb}GB — 하한 ${MIN_FREE_GB}GB 아래라 멈춥니다. 정리가 먼저입니다."
    return 2
  fi

  say "── 프로젝트 $P 시작 (오늘 $n/$DAILY_BUILD_CAP)"
  cd "$ROOT" || return 1

  # 크레딧을 쓰기 **전에** 시딩 누락부터 본다. 일괄 시딩이 segment_text·series_id·
  # info_instruction 을 차례로 빠뜨렸고, 셋 다 다 쓰고 나서야 드러났다 (2026-10-02).
  local sd; sd=$(call validate "{\"project_id\":$P,\"stage\":\"seed\"}")
  if [ "$(echo "$sd" | jget passed)" != "True" ]; then
    say "$P 시딩 미비로 건너뜀: $(echo "$sd" | python3 -c "import json,sys
print('; '.join(p.get('issue','') for p in json.load(sys.stdin).get('problems',[])))" 2>/dev/null)"
    return 1
  fi

  wait_idle || { say "$P: Flow 가 안 비어서 건너뜀"; return 1; }
  call flow_new_project "{\"project_id\":$P}" >/dev/null

  local g; g=$(gaps "$P")

  for st in clean info; do
    local need
    need=$(gap_of "$g" "$st")
    [ -z "$need" ] && continue
    local grp=""
    local cnt=0
    for n in $need; do
      grp="${grp:+$grp,}$n"
      cnt=$((cnt + 1))
      if [ "$cnt" -ge 4 ]; then
        wait_idle || return 1
        say "$P $st [$grp]"
        call flow_generate "{\"project_id\":$P,\"stage\":\"$st\",\"scene_nos\":[$grp]}" >/dev/null
        grp=""; cnt=0
      fi
    done
    if [ -n "$grp" ]; then
      wait_idle || return 1
      say "$P $st [$grp]"
      call flow_generate "{\"project_id\":$P,\"stage\":\"$st\",\"scene_nos\":[$grp]}" >/dev/null
    fi
  done

  # 승인창이 떠 있거나 Flow 가 막히면 몇 번을 돌려도 0개다. 166·167 이 장면 9개를
  # 두 바퀴, 매번 900초씩 기다려 4시간 반을 헛돌았다 (2026-10-04). 그게 CPU 를 끝까지
  # 물고 있었다. **한 바퀴 돌아 하나도 못 받으면 그 편은 접는다.**
  local before_try after_try
  for try in 1 2; do
    local miss
    g=$(gaps "$P")
    miss=$(gap_of "$g" "clip")
    [ -z "$miss" ] && break
    before_try=$(echo "$miss" | wc -w)
    for n in $miss; do
      wait_idle || return 1
      say "$P video [$n] (시도 $try)"
      call flow_generate "{\"project_id\":$P,\"stage\":\"video\",\"scene_nos\":[$n]}" >/dev/null
      wait_idle
    done

    after_try=$(gap_of "$(gaps "$P")" "clip" | wc -w)
    if [ "$after_try" -ge "$before_try" ]; then
      say "$P 영상이 한 바퀴를 돌아도 하나도 안 나왔습니다 ($before_try → $after_try). 이 편은 접습니다."
      return 1
    fi
  done
  wait_idle

  # **나레이션 결과를 버리지 않는다.** 처음엔 >/dev/null 로 삼켰다가, 장면에 대사가
  # 안 붙어 있어 실패한 것을 못 보고 그대로 합성까지 갔다 (실측 2026-10-02: 156번).
  say "$P 나레이션"
  local nr; nr=$(call generate_narration "{\"project_id\":$P}")
  if [ "$(echo "$nr" | jget ok)" != "True" ]; then
    say "$P 나레이션 실패: $(echo "$nr" | head -c 200)"
    return 1
  fi
  say "$P 나레이션 $(echo "$nr" | jget duration_sec)초"

  for _ in $(seq 1 40); do
    local r; r=$(call assemble "{\"project_id\":$P}")
    [ "$(echo "$r" | jget ok)" = "True" ] && {
      say "$P 합성 완료 $(echo "$r" | jget duration_sec)초"
      mark_built "$P"
      break
    }
    echo "$r" | grep -q '합성하는 중' || { say "$P 합성 실패: $(echo "$r" | head -c 160)"; break; }
    sleep 25
  done

  local v; v=$(call validate "{\"project_id\":$P,\"stage\":\"final\"}")
  say "$P 검증 passed=$(echo "$v" | jget passed)"
}

for P in "$@"; do
  build "$P"
  # 2 = 상한이나 디스크 때문에 멈춘 것이다. 다음 편으로 넘어가 봐야 똑같다.
  [ $? -eq 2 ] && { say "오늘은 여기까지 합니다."; break; }
done
say "워커 끝"
