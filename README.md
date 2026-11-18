# orchengine-tools

Tooling for Go repositories and OpenCode, originally built for
`~/Projects/OrchEngine`. Nothing here is imported by the OrchEngine module.

- [`go/`](go/README.md) — static call graphs, go-callvis, and field read/write
  graphs: `callgraph`, `go-callvis`, `fieldgraph`, `cg`.
- [`opencode-plugins/`](opencode-plugins/README.md) — OpenCode plugins and CLIs.

## Layout

- `go/bin/` — built Go binaries (git-ignored).
- `go/out/` — generated `.dot` / `.svg` graphs (git-ignored).
- `bin`, `out`, and `go-callvis` at the repo root are local compatibility
  symlinks to their `go/` counterparts, so old local paths keep working. They
  are not tracked.

## Quick start

```bash
cd /path/to/repo

# call graph for one package, written to go/out/<repo>/callgraph.svg
~/Projects/orchengine-tools/go/cg ./path/to/pkg

# field read/write graph for the whole module
~/Projects/orchengine-tools/go/bin/fieldgraph
```

The analysis commands are also on `PATH` through `~/.local/bin` symlinks:
`callgraph`, `go-callvis`, `fieldgraph`, and `cg`.
