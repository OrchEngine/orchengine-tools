#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

index="$target/.tmp/coverage/index.html"
if [ ! -f "$index" ]; then
    echo "run 'orche coverage' first" >&2
    exit 1
fi

if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$index" >/dev/null 2>&1 </dev/null &
    echo "Opened $index"
    exit 0
fi

echo "Open file://$index"
