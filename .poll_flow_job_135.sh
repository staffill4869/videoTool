#!/bin/bash
while true; do
  resp=$(curl -s -X POST http://127.0.0.1:4300/api/tools/flow_job -H "Content-Type: application/json" -d "{\"project_id\":135}")
  echo "$resp"
  echo "$resp" | grep -q '"state":"running"' || break
  sleep 30
done
