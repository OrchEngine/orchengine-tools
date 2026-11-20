#!/usr/bin/env bash
# End-to-end check: write a new .orch workflow, generate Zig, build, encode an
# event payload, and run the workflow from the CLI.
set -euo pipefail

target="${1:-$(pwd)}"
cd "$target" || exit 1

bin="${ZIG_OUT:-$target/zig-out}/bin/orchengine"
tmp="$target/.tmp/workflow-e2e"
rm -rf "$tmp"
mkdir -p "$tmp/definitions" "$tmp/generated"

cp customworkflows/definitions/*.orch "$tmp/definitions/"
cat > "$tmp/definitions/e2e.orch" <<'ORCH'
syntax "orch/v1"
id 0x1111111111111111
workflow e2e
event order_received: OrderReceived

step normalize_name = NormalizeName(name: order_received.customer_name)
step format_notification = FormatNotification(toAddress: order_received.email, userName: normalize_name.normalized)
ORCH

cat > "$tmp/definitions/e2e_conditional.orch" <<'ORCH'
syntax "orch/v1"
id 0x2222222222222222
workflow e2e_conditional
event name_submitted: NameSubmitted

data prefix: string = "A"

step has_prefix = HasPrefix(prefix: prefix, value: name_submitted.name)

if check_prefix(condition: has_prefix.matches) {
    step upper_name = ToUpper(value: name_submitted.name)
} else {
    step lower_name = ToLower(value: name_submitted.name)
}
ORCH

cat > "$tmp/definitions/e2e-dashed.orch" <<'ORCH'
syntax "orch/v1"
id 0x3333333333333333
workflow e2e-dashed
event order_received: OrderReceived

step normalize_name = NormalizeName(name: order_received.customer_name)
ORCH

mkdir -p "$tmp/invalid" "$tmp/duplicate"
cat > "$tmp/invalid/event_only.orch" <<'ORCH'
syntax "orch/v1"
workflow event_only
event order_received: OrderReceived
ORCH
if "$bin" generate-all \
    --workflows "$tmp/invalid" \
    --output "$tmp/rejected" \
    --definitions nodes >/dev/null 2>&1; then
    echo "generate-all accepted a runnable workflow without an id" >&2
    exit 1
fi

cp "$tmp/definitions/e2e.orch" "$tmp/duplicate/first.orch"
sed 's/workflow e2e/workflow duplicate/' "$tmp/definitions/e2e.orch" > "$tmp/duplicate/second.orch"
if "$bin" generate-all \
    --workflows "$tmp/duplicate" \
    --output "$tmp/rejected" \
    --definitions nodes >/dev/null 2>&1; then
    echo "generate-all accepted duplicate workflow ids" >&2
    exit 1
fi

"$bin" generate-all \
    --workflows "$tmp/definitions" \
    --output "$tmp/generated" \
    --definitions nodes

test -f "$tmp/generated/e2e_workflow_gen.zig"
test -f "$tmp/generated/e2e_conditional_workflow_gen.zig"
test -f "$tmp/generated/e2e-dashed_workflow_gen.zig"
test -f "$tmp/generated/workflows.zig"
test -f "$tmp/generated/registry.zon"
grep -q 'pub const manifest' "$tmp/generated/workflows.zig"
grep -q '@import("e2e_workflow_gen.zig")' "$tmp/generated/workflows.zig"
grep -q '@import("e2e_conditional_workflow_gen.zig")' "$tmp/generated/workflows.zig"
grep -q '@import("e2e-dashed_workflow_gen.zig")' "$tmp/generated/workflows.zig"
grep -A1 'name = "e2e",' "$tmp/generated/registry.zon" | grep -q 'event = "orchengine.events.v1.OrderReceived"'
grep -A1 'name = "e2e_conditional",' "$tmp/generated/registry.zon" | grep -q 'event = "orchengine.events.v1.NameSubmitted"'

zig build -p "$tmp/prefix" -Dworkflows-root=.tmp/workflow-e2e/generated/workflows.zig

printf 'customer_name: "  Ada   Lovelace "\nemail: "ada@example.com"\n' > "$tmp/input.text"
"$tmp/prefix/bin/orchengine" encode \
    --event orchengine.events.v1.OrderReceived \
    --in "$tmp/input.text" \
    --out "$tmp/input.bin"
"$tmp/prefix/bin/orchengine" run --workflow e2e --payload "$tmp/input.bin"
"$tmp/prefix/bin/orchengine" run --workflow e2e-dashed --payload "$tmp/input.bin"

printf 'name: "Ada"\n' > "$tmp/conditional.text"
"$tmp/prefix/bin/orchengine" encode \
    --event orchengine.events.v1.NameSubmitted \
    --in "$tmp/conditional.text" \
    --out "$tmp/conditional.bin"
"$tmp/prefix/bin/orchengine" run --workflow e2e_conditional --payload "$tmp/conditional.bin"

if "$tmp/prefix/bin/orchengine" run --workflow missing --payload "$tmp/input.bin" >/dev/null 2>&1; then
    echo "unknown workflow unexpectedly succeeded" >&2
    exit 1
fi
if "$tmp/prefix/bin/orchengine" run --workflow e2e >/dev/null 2>&1; then
    echo "run without a payload unexpectedly succeeded" >&2
    exit 1
fi
if "$tmp/prefix/bin/orchengine" encode --event orchengine.events.v1.Missing --in "$tmp/input.text" >/dev/null 2>&1; then
    echo "unknown event unexpectedly encoded" >&2
    exit 1
fi
printf '\x0a\xff' > "$tmp/bad.bin"
if "$tmp/prefix/bin/orchengine" run --workflow e2e --payload "$tmp/bad.bin" >/dev/null 2>&1; then
    echo "invalid payload unexpectedly ran" >&2
    exit 1
fi

echo "workflow e2e: wrote, generated, built, encoded, and ran successfully"
