#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

test_count="$(grep -R '^test ' src customworkflows --include='*.zig' | wc -l | tr -d ' ')"
test_files="$(grep -Rl '^test ' src customworkflows --include='*.zig' | wc -l | tr -d ' ')"
echo "test audit: ${test_count} test declarations across ${test_files} files"
echo "coverage report: .tmp/coverage/index.html"
