#!/bin/bash
while true; do
  resp=$(curl -s -X POST http://127.0.0.1:4300/api/tools/flow_job -H "Content-Type: application/json" -d '{"project_id":140}')
  echo "$resp"
  if echo "$resp" | grep -q '"status":"done"'; then
    break
  fi
  if echo "$resp" | grep -q '"status":"failed"'; then
    break
  fi
  sleep 60
done
