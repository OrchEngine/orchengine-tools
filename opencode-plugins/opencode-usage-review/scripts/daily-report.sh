#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/opencode-usage-review"
DAY="${1:-yesterday}"

mkdir -p "$STATE_DIR/daily" "$STATE_DIR/weekly" "$STATE_DIR/logs"

DATE="$(date -d "$DAY" +%F)"
LOG="$STATE_DIR/logs/$DATE.log"

{
  echo "generating $DATE"
  node "$ROOT/src/cli.ts" report --day "$DAY" --out "$STATE_DIR/daily/$DATE.md"
  ln -sfn "$STATE_DIR/daily/$DATE.md" "$STATE_DIR/latest.md"

  if [ "$(date -d "$DATE" +%u)" = "7" ]; then
    WEEK="$(date -d "$DATE" +%G-W%V)"
    echo "generating weekly $WEEK"
    node "$ROOT/src/cli.ts" report --days 7 --out "$STATE_DIR/weekly/$WEEK.md"
    ln -sfn "$STATE_DIR/weekly/$WEEK.md" "$STATE_DIR/latest-week.md"
  fi

  if command -v notify-send >/dev/null 2>&1; then
    SUMMARY="$(sed -n '/^## At a glance/,/^$/p' "$STATE_DIR/latest.md" | sed '1d;$d' | tr '\n' ' ')"
    notify-send "AI usage review ready" "${SUMMARY:-Open $STATE_DIR/latest.md}"
  fi
} >"$LOG" 2>&1
