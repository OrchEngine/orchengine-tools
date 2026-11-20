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
- `check` — merge zlint findings with zdepends project findings; artifacts stay in a unique `.tmp/check-*` directory on failure
- `verify` — check, gen-proto, build, test, TSan, generation check, workflow e2e
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
- `std_aliases.zig`, `no_deprecated.zig` (detection-only; no autofix)

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

Custom rule tests:

```bash
# uses the pinned zlint checkout
~/Projects/orchengine-tools/zig/zlint-rules-test

# custom zlint checkout
ZLINT_DIR=/path/to/zlint ~/Projects/orchengine-tools/zig/zlint-rules-test
```

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

A small NDepend-style report: hierarchical dependency graphs, call graph, call
stacks, recursion and import cycles, allocator/Io capability requirements, field
read/write ownership signals, and a heuristic technical-debt score. It writes a
single `report.html` (with Graphviz SVG embedded) plus the `.dot` / `.svg`
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
- `--graph-exclude <glob>` — hide matching files from the dependency graph only
  (repeatable).
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
  "graph": {
    "exclude": ["src/unit_tests.zig", "src/integration_tests.zig"]
  },
  "test_roots": ["src/unit_tests.zig", "src/integration_tests.zig"],
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
    "max-file-imports": 5,
    "module-cycle": 10
  },
  "project_rules": {
    "import-cycle": "warning",
    "module-cycle": "warning",
    "call-cycle": "warning",
    "uncalled-private-function": "warning",
    "architecture": "note",
    "test-only-import": "warning"
  },
  "suppressions": [
    {
      "rule": "import-cycle",
      "key": "src/a.zig,src/b.zig",
      "reason": "legacy cycle, scheduled for removal"
    }
  ]
}
```

Findings are weighted by rule ID when `weights` has an entry, otherwise by
severity defaults. Project configuration supplies OrchEngine-specific weights,
severities, and suppressions.

### Project rules and suppressions

Stable project rule IDs:

- `import-cycle`
- `module-cycle`
- `call-cycle`
- `uncalled-private-function`
- `architecture`
- `test-only-import`

`import-cycle`, `module-cycle`, and `test-only-import` are implemented. The
other IDs are schema-ready for their rule tickets. `project_rules` sets each
rule's severity (`error`, `warning`, `note`). Unknown IDs are rejected.

`module-cycle` aggregates resolved imports between top-level facades/modules and
reports SCC cycles such as `editor, workflowlower`. It is advisory by default:
use `"warning"` plus a weight to add debt without failing `--check`. Root files,
generated files, test-only imports, and files hidden by `graph.exclude` do not
participate. The suppression key is the sorted module list, for example
`editor,workflowlower`.

`test-only-import` rejects test-only dependency edges. An `@import` declared
inside a named `test` block is always reported, including direct
`_ = @import("...")` forms and imports in test roots: move the test to the
module that already owns the dependency, or to an integration test. Unnamed
`test { ... }` registration blocks are exempt, so test roots can keep importing
test files there. A file-scope aliased import that resolves to a local `.zig`
file is reported when every alias reference is inside a `test` declaration,
except in `test_roots`. Public `pub const` re-exports are facade API and stay
exempt. `test_roots` adds project-specific test roots to the built-in
`src/unit_tests.zig`, `src/integration_tests.zig`, and
`customworkflows/generated.zig` defaults; entries accept glob patterns. External
imports and generated files are skipped. The finding key is `<file>:<alias>`,
or `<file>:<raw>` for a direct import. Test-only imports do not contribute to
`module-cycle` edges.

`suppressions` entries require `rule`, `key`, and `reason`. The key is the
stable identity of the finding: sorted cycle members for cycles, the function
name for uncalled functions, or `<file>:<alias>` for test-only imports. Unknown
rules, missing keys, and missing reasons fail config loading before analysis.
Suppressed findings stay visible in the report with their reason and do not
affect `--check` or debt.

Precedence: defaults < `zigdepends.json` < CLI flags. Generated detection is
header-first (`Code generated ... DO NOT EDIT`, `@generated`) and does not
hardcode project paths; add unusual generators to `generated.paths` or
`generated.markers`. `exclude` removes files entirely, while `generated` keeps
them as import-boundary nodes. `graph.exclude` only hides matching files from
the dependency graph; analysis, findings, and debt still include them. The
`--graph-exclude <glob>` flag adds entries for one run.

Output:

- `report.html` — self-contained summary, findings, tables, cycles, call stacks,
  and an interactive dependency graph.
- `imports.dot` / `imports.svg` — the dependency graph source and a static
  fallback SVG. The report embeds one interactive graph instead of separate
  facade and file graphs.
- `calls.dot` / `calls.svg` — call graph of top-debt functions, recursion
  groups, and call-stack nodes.
- `fields.dot` / `fields.svg` — function → type field read/write graph.
- Generated files are excluded from function, debt, capability, and
  field-access metrics while remaining import boundary nodes.

The dependency hierarchy follows the repository convention: `src/<module>.zig`
is a facade, `src/<module>/` contains its internals, and a directory such as
`src/editor/graph/` becomes a submodule inside `editor` when `graph.zig` exists.
Facades and submodules are collapsible containers. Auto layout ranks
dependencies left to right; cycle-closing edges remain visible as feedback.
Dragging a file node moves only that file; dragging a container header moves the
whole subtree. Edges are redrawn while dragging and aggregated when a container
is collapsed. Use the wheel to zoom, the controls to fit/reset/collapse/expand,
and `graph.exclude` to keep noisy files such as test roots out of the dependency
view without removing them from analysis. `--no-graph` still writes every
`.dot` file.

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

Import cycles are emitted as `import-cycle` project findings. Module cycles are
emitted as `module-cycle` project findings; they are advisory by default and add
the configured weight to debt. Test-only imports are emitted as
`test-only-import` project findings. Call cycles are emitted as `call-cycle`
findings and support the same severities, weights, and suppressions.

The total is converted to hours and dev-days at 6 productive hours per day.
These are configurable estimates, not measurements.

### Limits

- Call resolution is syntactic and name-based; comptime dispatch, generics,
  function pointers, and variables with method calls remain unresolved. The
  report shows how many calls were resolved, unresolved, and external.
- `build.zig` is not interpreted; module imports are reported as unresolved
  boundaries instead of guessed.
- The facade hierarchy is path-based. A module is `src/<name>.zig` plus
  `src/<name>/`; nested submodules require a matching `<dir>/<name>.zig` facade
  file. Directories without that facade are rolled up into their parent module,
  so generated paths do not create artificial singleton submodules.
- Auto layout breaks import cycles, ranks the remaining graph, and orders nodes
  within each rank to reduce crossings. That is best-effort: crossings remain
  possible, and feedback edges are kept visible. `Reset` restores the original
  Graphviz positions.
- `module-cycle` aggregates to top-level modules only. Nested submodule cycles
  are visible in the graph but are not reported as separate findings.
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
