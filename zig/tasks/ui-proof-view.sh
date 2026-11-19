#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

if [ ! -d .tmp/ui-proof ]; then
    echo "run 'orche ui-proof' first" >&2
    exit 1
fi

node frontend/ui_test/gallery.mjs .tmp/ui-proof
