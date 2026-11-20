# orchengine-tools

Tooling for Go and Zig repositories and OpenCode, originally built for
`~/Projects/OrchEngine`. Nothing here is imported by the OrchEngine module.

- [`go/`](go/README.md) — static call graphs, go-callvis, and field read/write
  graphs: `callgraph`, `go-callvis`, `fieldgraph`, `cg`.
- [`zig/`](zig/README.md) — `zigdepends`: hierarchical facade/import graphs,
  call graphs, call stacks, cycles, generated-code filtering, allocator/Io
  capability tags, field read/write ownership signals, and a technical-debt HTML
  report for Zig code.
- [`opencode-plugins/`](opencode-plugins/README.md) — OpenCode plugins and CLIs.

## Layout

- `go/bin/` — built Go binaries (git-ignored).
- `go/out/` — generated Go `.dot` / `.svg` graphs (git-ignored).
- `zig/bin/` — built Zig binaries (git-ignored).
- `zig/out/` — generated Zig reports and graphs (git-ignored).
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

# Zig dependency/call/debt report, written to zig/out/<repo>/report.html and opened
~/Projects/orchengine-tools/zig/zigdepends ~/Projects/orchengine-zig
```

The Go analysis commands are also on `PATH` through `~/.local/bin` symlinks:
`callgraph`, `go-callvis`, `fieldgraph`, and `cg`. The Zig entry point is the
repo-local `zig/zigdepends` wrapper.
