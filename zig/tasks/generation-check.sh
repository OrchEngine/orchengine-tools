#!/usr/bin/env bash
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

bin="${ZIG_OUT:-$target/zig-out}/bin/orchengine"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$bin" generate-all \
    --workflows customworkflows/definitions \
    --output "$tmp"

list_generated() {
    local dir="$1"
    (cd "$dir" && find . -maxdepth 1 -type f \
        \( -name '*_workflow_gen.zig' -o -name 'workflows.zig' -o -name 'registry.zon' \) \
        -exec basename {} \; | sort)
}
expected="$(list_generated "$tmp")"
actual="$(list_generated customworkflows)"
if [ "$expected" != "$actual" ]; then
    echo "generated file set differs from the current definition set" >&2
    printf 'expected:\n%s\nactual:\n%s\n' "$expected" "$actual" >&2
    exit 1
fi

for file in $expected; do
    if ! cmp -s "$tmp/$file" "customworkflows/$file"; then
        echo "customworkflows/$file is stale; run 'zig build && ./zig-out/bin/orchengine generate-all'" >&2
        exit 1
    fi
done

if [ -n "$(git status --porcelain -- customworkflows/*_workflow_gen.zig customworkflows/workflows.zig customworkflows/registry.zon src/proto_gen)" ]; then
    git status --short -- customworkflows/*_workflow_gen.zig customworkflows/workflows.zig customworkflows/registry.zon src/proto_gen
    echo "generated files are stale; commit the regenerated output" >&2
    exit 1
fi
