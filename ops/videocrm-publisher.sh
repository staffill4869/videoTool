#!/bin/bash
# videoCRM 발행기. 대기열에 적힌 것만, 하루 상한 안에서 올린다.
#
# 발행은 **되돌리기 어려운 공개 행위**라서 자동으로 "올릴 만한 것"을 찾지 않는다.
# ops/publish-queue.txt 에 적힌 줄만 올린다.
#
# 상한에 걸리면 그 줄은 **대기열에 남겨 두고** 다음 실행(한 시간 뒤)에 다시 본다.
# 상한은 UTC 자정에 풀린다 — 한국시간 09:00.
set -u
. "$HOME/.asdf/asdf.sh" 2>/dev/null || true
API=http://127.0.0.1:4300/api/tools
ROOT=/home/ec2-user/videoCRM
QUEUE=$ROOT/ops/publish-queue.txt
DONE=$ROOT/ops/published.log
LOG=$ROOT/logs/publisher.log
mkdir -p "$ROOT/logs" "$ROOT/ops"
touch "$QUEUE" "$DONE"

say() { echo "[$(date -u +'%F %T') UTC] $*" | tee -a "$LOG"; }

# 한 번에 하나만 돈다. 두 번 돌면 같은 줄을 두 번 올릴 수 있다.
exec 9>"$ROOT/ops/.publisher.lock"
flock -n 9 || { say "이미 돌고 있어 건너뜀"; exit 0; }

jget() { python3 -c "import json,sys
try: d=json.load(sys.stdin)
except Exception: print(''); raise SystemExit
print(d.get('$1',''))" 2>/dev/null; }

rest=""
capped=""

while read -r pid slug _; do
  case "$pid" in ''|'#'*) rest="$rest
$pid $slug"; continue ;; esac
  [ -z "${slug:-}" ] && continue

  # 이 채널이 이번 실행에서 이미 상한에 걸렸으면 더 시도하지 않는다.
  case " $capped " in *" $slug "*) rest="$rest
$pid $slug"; continue ;; esac

  out=$(curl -s --max-time 900 -X POST "$API/publish" -H 'content-type: application/json' \
          -d "{\"project_id\":$pid,\"channel_slug\":\"$slug\",\"confirm\":true}")

  if [ "$(echo "$out" | jget ok)" = "True" ]; then
    url=$(echo "$out" | jget url)
    say "올림 $pid → $slug $url"
    echo "$(date -u +'%F %T') $pid $slug $url" >> "$DONE"
  else
    err=$(echo "$out" | jget error)
    say "못 올림 $pid → $slug :: ${err:-$(echo "$out" | head -c 160)}"
    case "$err" in *상한*) capped="$capped $slug" ;; esac
    rest="$rest
$pid $slug"
  fi
done < "$QUEUE"

# 남은 줄만 다시 쓴다. 빈 줄은 버린다.
printf '%s\n' "$rest" | sed '/^$/d' > "$QUEUE.tmp" && mv "$QUEUE.tmp" "$QUEUE"
say "끝 — 대기열 $(grep -cvE '^\s*(#|$)' "$QUEUE") 줄 남음"
