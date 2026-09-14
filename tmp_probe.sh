#!/bin/sh
for i in 13 15 16 17 21 27 30 31 32 33 34 35 49 50; do
  f="C:/rebase/videoCRM/projects/$i/final.mp4"
  printf "%s " "$i"
  ffprobe -v error -select_streams v:0 -show_entries stream=width,height -show_entries format=duration -of csv=p=0:nw=1 "$f" | tr '\n' ' '
  stat -c '%y' "$f" | cut -c1-16
done
