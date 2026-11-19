# Zig tooling

Static analysis for Zig projects, built for `~/Projects/orchengine-zig`. Like
the Go tools, nothing here is imported by the analyzed project.

## orche

`orche` is the tooling runner. It operates on a target checkout and keeps all
tool implementation out of the analyzed repository.

```bash
cd ~/Projects/orchengine-tools/zig
zig build -Doptimize=ReleaseSafe

# local source build of zlint + full gate
./zig-out/bin/orche verify ~/Projects/orchengine-zig

# CI: use the pinned prebuilt zlint
./zig-out/bin/orche verify --release ~/Projects/orchengine-zig
```

Commands:

- `lint` — build/select zlint, run it, and `zig fmt --check`
- `check` — merge zlint findings with zdepends project findings
- `verify` — lint, gen-proto, build, test, TSan, generation check, workflow e2e
- `e2e`, `generation-check`
- `coverage`, `coverage-view`, `test-audit`
- `ui-proof`, `ui-proof-view`
- `typecheck-js`, `test-js`, `build-ui`, `test-ui`, `test-ui-update`, `watch-ui`

`orche` is Linux-only for now. The multiplatform follow-up is
[#26](https://github.com/OrchEngine/orchengine-tools/issues/26).

## zlint rules

OrchEngine's per-file zlint rules live in `zlint_rules/` and are compiled into
a zlint binary at build time. The zlint fork is cloned into `zlint/`
(gitignored) by `zlint-src` and pinned by `zlint.lock`; it only carries Zig
0.17.1 compatibility.

Rules:

- `max_function_lines.zig`, `max_complexity.zig`, `max_params.zig`,
  `max_nesting.zig`
- `production_file_size.zig`, `max_file_imports.zig`
- `forbid_casts.zig`, `mutual_type_cycles.zig`,
  `uncalled_private_function.zig`

Build:

```bash
# default zlint checkout
~/Projects/orchengine-tools/zig/zlint-rules-build

# custom zlint checkout
ZLINT_DIR=/path/to/zlint ~/Projects/orchengine-tools/zig/zlint-rules-build
```

The binary is written to `zig/bin/zlint-orche`. zlint compiles custom rules as
static inputs; pass one `-Dcustom_rules=<path>` flag per rule. Comma-separated
paths do not work.

Strict parity:

```bash
~/Projects/orchengine-tools/zig/zlint-rules-parity ~/Projects/orchengine-zig
```

The script builds the fork-bundled and external variants, runs both with the
project's `zlint.json`, and requires identical normalized JSON findings and exit
codes on both the project snapshot and the all-rule fixture under
`zlint_rules/testdata/parity/`.

Rule thresholds, severities, and allowlists are project configuration and stay
in the analyzed repository, not here.

### Prebuilt release

CI consumes a pinned prebuilt binary instead of building zlint on every run.

```bash
# build the host artifact, run strict fixture parity, write out/release/
~/Projects/orchengine-tools/zig/zlint-release
```

`zig/zlint.lock` pins the zlint commit. The release workflow at
`.github/workflows/zlint-release.yml` builds the same artifact on a
`zlint-v*` tag for `linux-x86_64`, runs strict parity against the bundled
rules, publishes the tarball and its SHA256, and prints the checksum for the
consumer pin.

The binary contains the rule set from this repository at that commit. Changing
a rule requires a new release; use the source build during rule development.

## zigdepends

A small NDepend-style report: dependency graph, call graph, call stacks,
recursion and import cycles, allocator/Io capability requirements, field
read/write ownership signals, and a heuristic technical-debt score. It writes
a single `report.html` (with Graphviz SVG embedded) plus the `.dot` / `.svg`
sources next to it, then opens the HTML in the default browser. Generated files
are detected by their standard header and excluded from metrics while remaining
visible as import boundaries.

### Build

```bash
~/Projects/orchengine-tools/zig/zigdepends-build
# installs zig/bin/zigdepends
```

`zigdepends` is also a wrapper that builds on first use:

```bash
~/Projects/orchengine-tools/zig/zigdepends ~/Projects/orchengine-zig
```

Requires Zig 0.17.1 and Graphviz `dot`. Analysis itself has no dependencies
beyond the Zig standard library.

### Usage

```bash
# report in zig/out/<project>/ and open it
zigdepends ~/Projects/orchengine-zig

# explicit output directory and title
zigdepends -o /tmp/report --title "OrchEngine Zig" ~/Projects/orchengine-zig

# only show functions with at least 30 debt minutes; skip graphs; no browser
zigdepends --min-debt 30 --no-graph --no-open .
```

Flags:

- `-o, --out <dir>` — output directory; default
  `~/Projects/orchengine-tools/zig/out/<project>`.
- `--title <text>` — report title; default is the project directory name.
- `--min-debt <n>` — hide functions below `n` debt minutes.
- `--max-call-nodes <n>` — cap the call graph at `n` functions (default 80).
- `--no-graph` — skip Graphviz; the HTML report is still written.
- `--no-open` — do not open the report in a browser (default opens it).
- `--config <file>` — read a `zigdepends.json`; default is
  `<analyzed-path>/zigdepends.json` when present.
- `--exclude <glob>` — fully exclude a file or directory (repeatable).
- `--include-generated` — analyze generated bodies instead of boundary mode.
- `--list-files` — print source / generated / excluded classification.
- `--no-capabilities` — skip allocator/Io capability analysis.
- `--no-fields` — skip field read/write and ownership analysis.
- `--debug-io` — count `std.debug.print`, `std.debug.info`, and `std.log` as Io requirements
  (off by default).
- `--check` — print findings and exit nonzero on errors; no report or browser.
- `--format text|json` — check output format (default: text).
- `--zlint-report <file>` — read zlint `--format json` JSONL findings.

### Configuration

```json
{
  "version": 1,
  "exclude": ["vendor/**"],
  "generated": {
    "markers": ["@generated"],
    "paths": ["src/proto_gen/**", "customworkflows/**/*_gen.zig"],
    "include_in_metrics": false
  },
  "capabilities": {
    "debug_io": false,
    "track": true
  },
  "fields": {
    "track": true
  },
  "findings": {
    "error": 10,
    "warning": 1,
    "note": 0
  },
  "weights": {
    "max-file-imports": 5
  }
}
```

Findings are weighted by rule ID when `weights` has an entry, otherwise by
severity defaults. Project configuration supplies OrchEngine-specific weights
and allowlists.

Precedence: defaults < `zigdepends.json` < CLI flags. Generated detection is
header-first (`Code generated ... DO NOT EDIT`, `@generated`) and does not
hardcode project paths; add unusual generators to `generated.paths` or
`generated.markers`. `exclude` removes files entirely, while `generated` keeps
them as import-boundary nodes.

Output:

- `report.html` — self-contained summary, findings, tables, cycles, call stacks,
  and inline SVG graphs.
- `imports.dot` / `imports.svg` — file import graph.
- `calls.dot` / `calls.svg` — call graph of top-debt functions, recursion
  groups, and call-stack nodes.
- `fields.dot` / `fields.svg` — function → type field read/write graph.
- Generated files are excluded from function, debt, capability, and
  field-access metrics while remaining import boundary nodes.

### What it extracts

- Files, functions, parameters, `pub` status, doc comments.
- Relative `@import("...")` edges. `std`, `builtin`, and `root` are external;
  module names from `build.zig` are listed as unresolved boundaries.
- Direct calls, with heuristic resolution:
  - unqualified call → unique function in the same file, then globally unique;
  - `self.foo()` → method named `foo` on the caller's enclosing container;
  - `Type.foo()` → method on that container in the same file;
  - `alias.foo()` → function/method in the file imported as `alias`;
  - `x.foo()` where `x` is a variable → unresolved. Type inference is out of
    scope for this version.
- Function LOC, cyclomatic proxy, control-flow nesting, and parameter counts as
  display-only metrics. They do not create rules or debt.
- Capability requirements:
  - direct: `std.mem.Allocator`, `std.Io`/`Io.Writer`/`Io.Reader`/`Io.Dir`/
    `Io.File` parameters, `std.process.Init`, allocator/Io API calls, and
    `self.allocator` / `self.io` field access;
  - inherited: requirements propagated from callees to callers through the
    resolved call graph;
  - unattributed: inherited requirements with no visible parameter, field, or local
    source.
- Generated files: standard generated headers are detected in the first lines;
  their imports are kept for the dependency graph, but their functions are not
  analyzed unless `--include-generated` is passed.
- Field accesses: `self.field`, typed parameters/locals, nested fields, and
  static `Type.field`; assignments and compound assignments count as writes.
- Ownership signals: allocator/Io fields, pointer/slice fields, and
  `init`/`create`/`deinit`/`destroy`/`free` candidates per type.

Vendored/generated directories (`zig-cache`, `zig-out`, `zig-pkg`, `.tmp`,
`node_modules`, `.git`) are skipped by default. `std.debug.print` and
`std.log` are tracked as debug/logging, not as Io, unless `--debug-io` is set.

### Findings and debt

`--zlint-report` ingests zlint's `--format json` output. Debt is the sum of
non-suppressed finding weights. Defaults are 10 minutes per error, 1 per
warning, and 0 per note; `weights` overrides individual rule IDs.

Function LOC, cyclomatic proxy, nesting, and parameter counts remain visible as
display-only metrics. They do not create findings or debt.

Import and call cycles are shown in the report. Gating them as project rules is
tracked separately. Self-recursion is normally intentional.

The total is converted to hours and dev-days at 6 productive hours per day.
These are configurable estimates, not measurements.

### Limits

- Call resolution is syntactic and name-based; comptime dispatch, generics,
  function pointers, and variables with method calls remain unresolved. The
  report shows how many calls were resolved, unresolved, and external.
- `build.zig` is not interpreted; module imports are reported as unresolved
  boundaries instead of guessed.
- Import cycles are legal in Zig (`@import` is lazy); the report highlights
  them as architectural coupling, not as compiler errors.
- Capability detection is heuristic: allocator/Io stored in a struct field is
  recognized when its field type contains `Allocator`/`Io`, but aliases,
  comptime polymorphism, and unresolved calls can hide requirements. The
  “unattributed requirements” list is intentionally conservative.
- Field access is intraprocedural and type-name based; imported types, return
  values, slices of structs, function-pointer dispatch, and mutations through
  method calls remain unresolved. Struct-literal initializers are not counted
  as field writes. Ownership markers are signals, not proofs.
- `std.debug.info` is not part of Zig 0.17's stdlib; it is matched textually so
  a user-defined helper with that name still triggers the debug-output rule.
  `std.debug.print` and `std.log.debug/info` are the real stdlib patterns.
- `@ptrCast`/`catch unreachable` counts are textual and include comments/tests.
