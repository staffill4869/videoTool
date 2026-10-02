#!/bin/bash
prev_status="none"
while true; do
  resp=$(curl -s -X POST http://127.0.0.1:4300/api/tools/flow_job -H 'Content-Type: application/json' -d '{"project_id":104}')
  cur_status=$(printf '%s' "$resp" | grep -o '"status":"[^"]*"' | head -1)
  if [ "$cur_status" != "$prev_status" ]; then
    echo "$(date +%H:%M:%S) $resp"
    prev_status="$cur_status"
  fi
  case "$cur_status" in
    *done*|*failed*|*error*)
      echo "TERMINAL: $cur_status"
      exit 0
      ;;
  esac
  sleep 60
done
