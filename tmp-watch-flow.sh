#!/bin/sh
# 임시: flow_job 상태를 60초 간격으로 보고 바뀔 때만 한 줄 낸다. 끝나면 종료.
PID="$1"
prev=""
i=0
while [ "$i" -lt 20 ]; do
  s=$(curl -sS -m 20 -X POST http://127.0.0.1:4300/api/tools/flow_job \
        -H "Content-Type: application/json" \
        -d "{\"project_id\":$PID}" 2>&1 || true)
  cur=$(printf '%s' "$s" | tr ',{}' '\n\n\n' | grep -E '"(state|error|assets|harvested)"' | tr '\n' ' ')
  if [ "$cur" != "$prev" ]; then
    echo "flow_job $PID: $cur"
    prev="$cur"
  fi
  case "$cur" in
    *done*|*failed*|*error*|*cancel*) echo "TERMINAL $PID: $cur"; exit 0 ;;
  esac
  i=$((i + 1))
  sleep 60
done
echo "WATCH TIMEOUT $PID: $prev"
