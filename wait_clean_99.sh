#!/bin/bash
target_dir="/home/ec2-user/videoCRM/projects/99"
while true; do
  count=$(find "$target_dir" -type f | wc -l)
  if [ "$count" -ge 8 ]; then
    echo clean_ready
    break
  fi
  sleep 30
done
