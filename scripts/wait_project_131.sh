#!/bin/bash
while true; do
  r=$(curl -s -X POST http://127.0.0.1:4300/api/tools/status -H "Content-Type: application/json" -d '{"project_id":131}')
  echo "$r" | grep -q "narrated" || break
  sleep 60
done
echo done
