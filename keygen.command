#!/bin/bash
# BetterDisplay Free — launcher + local licence server control.
#   ./keygen.command          start server (if needed) + open app
#   ./keygen.command stop     stop the server
#   ./keygen.command status   show server/app status
set -u
cd "$(dirname "$0")"
PORT="$(python3 -c 'import json;print(json.load(open("config.json")).get("port",8543))' 2>/dev/null || echo 8543)"
APP="${BD_APP:-/Applications/BetterDisplay Free.app}"
SERVER="$PWD/bd_keygen_server.py"
LOG="$PWD/bd_keygen_server.log"

case "${1:-start}" in
  stop)
    pkill -f "bd_keygen_server.py" 2>/dev/null && echo "server stopped" || echo "server not running"
    exit 0
    ;;
  status)
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "server: RUNNING (:$PORT)"
    else
      echo "server: stopped"
    fi
    if pgrep -f "$APP/Contents/MacOS/BetterDisplay" >/dev/null 2>&1; then
      echo "app: running"
    else
      echo "app: not running"
    fi
    exit 0
    ;;
esac

if [ ! -d "$APP" ]; then
  echo "!! $APP not found." >&2
  echo "   Run: bash patch_copy.sh" >&2
  exit 1
fi

if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "→ starting local licence server on 127.0.0.1:$PORT"
  nohup python3 "$SERVER" >> "$LOG" 2>&1 &
  sleep 1
fi

if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "!! server failed to start — see $LOG" >&2
  tail -20 "$LOG" 2>/dev/null >&2
  exit 1
fi
echo "→ server OK (:$PORT)"

if pgrep -f "$APP/Contents/MacOS/BetterDisplay" >/dev/null 2>&1; then
  echo "→ BetterDisplay already running"
else
  echo "→ BetterDisplay launched"
  nohup "$APP/Contents/MacOS/BetterDisplay" >/dev/null 2>&1 &
  sleep 1
  if ! pgrep -f "$APP/Contents/MacOS/BetterDisplay" >/dev/null 2>&1; then
    open -n "$APP" 2>/dev/null || true
  fi
fi

echo
echo "Activate in the app: menu bar → BetterDisplay → Activate License…"
echo "Any key works, e.g.  BETTER-DISPLAY-KEYGEN-0001"
