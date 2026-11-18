# Changelog

## 0.1.0 — 2026-11-08

- Daily and weekly Markdown/JSON reports from the OpenCode SQLite history.
- OpenCode Go quota windows from `@slkiser/opencode-quota`, with per-session list value.
- Active time merged across overlapping sessions; fork inheritance deduplicated; subagents included.
- Activity attribution: exploration, analysis, writing, fixing/failure handling, verification, planning, interaction, other.
- Agent economics: read/analysis per $1 written, verification per $1 written, pre-first-edit share.
- Exploration efficiency: read amplification, full-file share, exact/redundant/post-compaction repeats, top repeated reads and searches.
- Model mix and per-model cost per step.
- Rework hotspots, context pressure, compactions, and long-lived sessions.
- Outcome labels: useful / rework / abandoned / explore.
- History snapshots with `history list`, `history show`, and `history compare`.
- Done log with `done add` / `done list`; done items appear in reports and snapshots.
- TUI commands: `/usage-review`, `/usage-week`, `/usage-label`.
- Agent tools: `outline` and `smart_read`.
  - `outline` uses `gopls symbols` for Go and built-in parsers for TypeScript/JavaScript, Python, Rust, Markdown, and YAML.
  - `smart_read` returns outlines for large files, caches unchanged ranges per session, and invalidates the cache after file changes or compaction.
- OrchEngine integration: gopls MCP project config and the `orchengine-exploration` skill.
- Test suite: 20 tests covering fixtures, fork handling, active time, activity attribution, exploration stats, history, done items, outlines, and smart-read caching.
