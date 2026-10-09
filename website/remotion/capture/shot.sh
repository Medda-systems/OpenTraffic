#!/bin/zsh
# shot.sh <window: popover|main|newTunnel> <output.png> [command-json]
# Applies an optional command, waits for it to render, then captures the real window.
win=$1; out=$2; cmd=$3
if [[ -n "$cmd" ]]; then
  before=$(cat /tmp/ot-capture/ack.txt 2>/dev/null || echo 0)
  print -r -- "$cmd" > /tmp/ot-capture/command.json
  for i in {1..60}; do [[ "$(cat /tmp/ot-capture/ack.txt 2>/dev/null || echo 0)" != "$before" ]] && break; sleep 0.1; done
  [[ "$(cat /tmp/ot-capture/ack.txt 2>/dev/null || echo 0)" == "$before" ]] && { echo "shot.sh: $cmd wasn't applied" >&2; exit 1; }
  sleep ${SETTLE:-1.2}
fi
wid=$(python3 -c "import json;print(json.load(open('/tmp/ot-capture/windows.json'))['$win'])")
screencapture -x -o -l "$wid" "$out"
