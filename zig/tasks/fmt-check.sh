#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

zig fmt --check build.zig src/*.zig customworkflows/*.zig
