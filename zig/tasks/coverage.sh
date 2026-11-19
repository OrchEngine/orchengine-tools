#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

if ! command -v kcov >/dev/null 2>&1; then
    echo "coverage: kcov is not installed" >&2
    exit 1
fi

bin_dir="${ZIG_OUT:-$target/zig-out}/bin"
rm -rf .tmp/coverage .tmp/coverage-root .tmp/coverage-nodes .tmp/coverage-generated

kcov --include-pattern=src/ .tmp/coverage-root "$bin_dir/orchengine-test"
kcov --include-pattern=src/ .tmp/coverage-nodes "$bin_dir/orchengine-test-nodes"
kcov --include-pattern=customworkflows/ .tmp/coverage-generated "$bin_dir/orchengine-test-generated"
kcov --merge .tmp/coverage .tmp/coverage-root .tmp/coverage-nodes .tmp/coverage-generated
