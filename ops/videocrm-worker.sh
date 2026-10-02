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

# 아직 클립이 없는 장면 번호들
missing() { PRJ=$1 MIX_ENV=dev mix run /tmp/missing.exs 2>/dev/null | grep '^MISS' | sed 's/^MISS *//'; }

stage_for() {  # 어느 단계가 비어 있나
  PRJ=$1 MIX_ENV=dev mix run /tmp/stage.exs 2>/dev/null | grep '^STAGE' | sed 's/^STAGE //'
}

build() {
  local P=$1
  say "── 프로젝트 $P 시작"
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

  for st in clean info; do
    local need
    need=$(stage_for "$P" | tr ' ' '\n' | grep "^$st:" | cut -d: -f2)
    [ -z "$need" ] && continue
    for grp in "1,2,3,4" "5,6,7,8"; do
      wait_idle || return 1
      say "$P $st [$grp]"
      call flow_generate "{\"project_id\":$P,\"stage\":\"$st\",\"scene_nos\":[$grp]}" >/dev/null
    done
  done

  for try in 1 2; do
    local miss
    miss=$(missing "$P")
    [ -z "$miss" ] && break
    for n in $miss; do
      wait_idle || return 1
      say "$P video [$n] (시도 $try)"
      call flow_generate "{\"project_id\":$P,\"stage\":\"video\",\"scene_nos\":[$n]}" >/dev/null
      wait_idle
    done
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
    [ "$(echo "$r" | jget ok)" = "True" ] && { say "$P 합성 완료 $(echo "$r" | jget duration_sec)초"; break; }
    echo "$r" | grep -q '합성하는 중' || { say "$P 합성 실패: $(echo "$r" | head -c 160)"; break; }
    sleep 25
  done

  local v; v=$(call validate "{\"project_id\":$P,\"stage\":\"final\"}")
  say "$P 검증 passed=$(echo "$v" | jget passed)"
}

for P in "$@"; do
  build "$P"
done
say "워커 끝"
