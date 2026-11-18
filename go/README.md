# Go tooling

Go analysis tools, originally built for `~/Projects/OrchEngine`. Nothing here
is imported by the OrchEngine module.

The `callgraph`, `go-callvis`, `fieldgraph`, and `cg` tools are not tied to
OrchEngine: run them from any Go module.

## Binaries

Installed in `go/bin/` and exposed on `PATH` through `~/.local/bin` symlinks.

- `callgraph` — `golang.org/x/tools/cmd/callgraph`; static call graphs.
- `go-callvis` — v0.7.1 rebuilt against `x/tools` v0.53.0. Upstream pins
  v0.28.0, whose SSA builder panics on Go 1.27 syntax.
- `fieldgraph` — struct/field read/write graph for a package.

## Setup

From a fresh checkout:

```bash
./go/callgraph-build
./go/go-callvis-build
./go/fieldgraph-build

ln -sfn "$PWD/go/bin/callgraph" "$HOME/.local/bin/callgraph"
ln -sfn "$PWD/go/bin/go-callvis" "$HOME/.local/bin/go-callvis"
ln -sfn "$PWD/go/bin/fieldgraph" "$HOME/.local/bin/fieldgraph"
ln -sfn "$PWD/go/cg" "$HOME/.local/bin/cg"
```

`~/.local/bin` must be on `PATH`. The root `bin`, `out`, and `go-callvis`
symlinks are only local compatibility shortcuts; a fresh clone does not need
them.

## Scripts

- `cg` — wraps `callgraph`, filters to the current module, renders DOT and SVG.
  The module path is detected with `go list -m`; set `MODULE=...` to override it.

  ```bash
  cd /path/to/repo
  ~/Projects/orchengine-tools/go/cg -a vta -f internal/editor \
    -o ~/Projects/orchengine-tools/go/out/myrepo/callgraph.svg ./internal/editor
  ```

- `callgraph-build` — reinstalls the latest `x/tools` callgraph into `go/bin/`.
- `go-callvis-build` — re-clones upstream, bumps `x/tools@latest`, rebuilds
  `go/bin/go-callvis`.
- `fieldgraph-build` — rebuilds `go/bin/fieldgraph` from `fieldgraph/`.

## fieldgraph

Static field-access graph for one package plus its direct in-module imports.
For `internal/editor` it shows which files, types, or functions read and write
which struct fields, plus file reads/writes.

```bash
cd /path/to/repo
~/Projects/orchengine-tools/go/bin/fieldgraph
```

The defaults analyze the whole current module (`-pkg ./...`) and write
`fieldgraph.dot` / `fieldgraph.svg` under
`~/Projects/orchengine-tools/go/out/<dir>/`. Narrow it for a specific package:

```bash
cd ~/Projects/OrchEngine
~/Projects/orchengine-tools/go/bin/fieldgraph \
  -pkg ./internal/editor \
  -out ~/Projects/orchengine-tools/go/out/editor
```

### Grouping

- `-group file` (default) — source nodes are `.go` files; this is the readable
  overview. `workflow_store.go → Workflow` etc.
- `-group type` — methods collapse into their receiver type; free functions
  stay separate.
- `-group func` — one node per function/method; use this for drill-down.

### Edges

- **blue** `read Field, …` — a field read
- **red** `write Field, …` — a field write
- **orange dashed** `reads file` / `writes file` — file I/O reached through the
  package's direct imports
- edge labels show up to two field names; SVG tooltips show every field and the
  source `file:line`

### Other flags

- `-calls` — add call edges and the full function graph. Off by default because
  calls dominate the picture.
- `-focus Name` — keep only structs whose name contains `Name`, plus the files,
  types, or functions touching them. Example:
  `-focus EditorGraph` gives a small read/write neighborhood.
- `-io=false` — omit file read/write nodes.
- `-tests` — include test code.
- `-layout dot|neato|sfdp|fdp` — default is `sfdp` for file/type views and `dot`
  for the function view. `dot` gives a clean but very tall bipartite graph;
  `sfdp` is compact.
- `-dir` — module root; defaults to the current directory.
- `-pkg` — package pattern; defaults to `./...`.
- `-out` — output base path; defaults to
  `<tools>/go/out/<dir>/fieldgraph`.

### Limits

- Only direct field access is attributed: `x.F = v` and struct literals. A
  method that mutates its receiver internally is attributed to that method's
  file/type, not to its callers.
- Writes through pointers (`&x.F`) and reflection are not detected.
- `x.F[i] = v` is recorded as a read of `F`, because the slice or map header is
  read; the element write is not attributed to the field.
- File I/O edges are reachability-based: a file or type that can reach a
  read/write through its calls is marked, even if the actual `os.ReadFile` is
  several calls away.
- Interface dispatch is shown as calls, not as data flow.
- Only direct in-module imports are shown as boundary structs; stdlib and
  third-party fields are ignored.

## Patches

- `patches/go-callvis-x-tools.patch` — the local `x/tools` bump that makes
  go-callvis v0.7.1 parse Go 1.27 code.

## Output

`go/out/` holds generated `.dot` / `.svg` files. Treat it as disposable.
