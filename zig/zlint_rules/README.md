# zlint custom rules

OrchEngine-specific per-file zlint rules. These are compiled into a zlint
binary with `-Dcustom_rules`; they do not live in the zlint fork.

The zlint fork at `orchengine-zig/tools/zlint` is only the Zig 0.17.1
compatibility fork. Custom rules and project policy live here.

## Rules

- `max_function_lines.zig`
- `max_complexity.zig`
- `max_params.zig`
- `max_nesting.zig`
- `production_file_size.zig`
- `max_file_imports.zig`
- `deinit_returns_void.zig`
- `forbid_casts.zig`
- `mutual_type_cycles.zig`
- `uncalled_private_function.zig`
- `prefer_unmanaged.zig`

## Build

```bash
# default zlint checkout
ZLINT_DIR=~/Projects/orchengine-zig/tools/zlint \
  ~/Projects/orchengine-tools/zig/zlint-rules-build

# custom checkout
ZLINT_DIR=/path/to/zlint ~/Projects/orchengine-tools/zig/zlint-rules-build
```

The binary is written to `zig/bin/zlint-orche`.

## Strict parity

Until the rules are removed from the fork, compare bundled and external rules
on a frozen project snapshot:

```bash
~/Projects/orchengine-tools/zig/zlint-rules-parity ~/Projects/orchengine-zig
```

The script builds both variants, runs them with the project's `zlint.json`,
normalizes the JSON output, and fails on any difference.

## Ownership

- Per-file zlint rules: this directory.
- Cross-file project rules: `zig/zdepends`.
- zlint compatibility: `OrchEngine/zlint` fork.
- OrchEngine thresholds/allowlists: `orchengine-zig` configuration.
