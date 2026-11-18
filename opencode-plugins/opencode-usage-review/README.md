# opencode-usage-review

A local, deterministic daily review of how you use OpenCode: quota burn, active time, rework, context pressure, and outcome labels.

It is not a token counter. The goal is to answer three questions:

1. Where did my quota and money go?
2. Where did my time go?
3. What should I change tomorrow?

## What it reads

- `~/.local/share/opencode/opencode.db` — session and message history, opened **read-only**.
- `opencode-quota`'s live snapshot (optional) for current OpenCode Go 5h / weekly / monthly limits.
- `~/.local/state/opencode-usage-review/labels.json` — your outcome labels.

It never sends a report to the model. In the TUI plugin, `/usage-review` opens a local dialog; nothing is added to the conversation context.

## Requirements

- Node.js 22.13 or newer (this project is tested on Node 26).
- OpenCode 2.x.
- Optional: [`@slkiser/opencode-quota`](https://github.com/slkiser/opencode-quota) for exact Go quota windows. Install it with `opencode plugin add @slkiser/opencode-quota`; the report falls back gracefully when it is absent.

## Quick start

```bash
npm install
npm link   # optional: puts opencode-usage-review on PATH
node src/cli.ts report --day today
node src/cli.ts report --days 7
node src/cli.ts history compare
node src/cli.ts done add "Finished the migration"
node src/cli.ts report --day yesterday --out /tmp/yesterday.md
```

Print JSON instead of Markdown:

```bash
node src/cli.ts report --day today --json
```

## What the report contains

- **Quota (current)**: 5h, weekly, and monthly OpenCode Go windows, with a warning below 20%.
- **At a glance**: sessions, prompts, steps, tool calls, active time, inactivity, list-price value, steps per prompt, tool calls per step, and reasoning share.
- **Where the tokens went**: exploration, analysis/tooling, writing, fixing/failure handling, verification, planning, and interaction. Includes a per-tool table and a per-session mix.
- **Agent economics**: reading/analysis per $1 of writing, verification per $1 of writing, fixing per $1 of writing, planning per prompt, fixing + verification share, and how much value was spent before the first edit.
- **Rework hotspots**: sessions ranked by fixing + verification cost, with failed commands, command retries, and redundant reads.
- **Top sessions by list value** and **by active time**.
- **Model mix**: steps, list value, share, and cost per step by model. This is where a few expensive steps (for example Claude) can outweigh thousands of cheap DeepSeek steps.
- **Leaks and evidence**: redundant reads, repeated commands, failed retries, compactions, context pressure, long-lived sessions, large tool outputs.
- **Outcome labels**: useful / rework / abandoned / explore, and the list value attached to each.
- **Experiments for tomorrow**: rule-triggered suggestions.
- **Appendix**: every session with its ID, so you can open it with `opencode -s <id>`.

### Why list value, not billed cost

OpenCode Go is a subscription, so the database reports `cost = 0`. The report computes a **list-price equivalent** from model prices and tokens so sessions can be compared. It is not your invoice, and it is not the same as Go's weighted allowance. Exact quota percentages come from `opencode-quota`; per-session list value is only a ranking aid.

## Labels

Label the sessions you actually care about. This is the only reliable ground truth for whether a session was wasteful.

```bash
node src/cli.ts labels set ses_abc123 useful --note "shipped the parser"
node src/cli.ts labels set ses_def456 rework --note "same test failed 6 times" --task debug
node src/cli.ts labels set ses_ghi789 abandoned --task explore
node src/cli.ts labels remove ses_ghi789
node src/cli.ts labels list
```

Weekly reports show the list value attached to each outcome.

## Daily Markdown and weekly rollup

The included systemd units generate yesterday's report at 00:10. When yesterday was a Sunday, the same run also writes a weekly rollup for the week that just ended.

```bash
mkdir -p ~/.config/systemd/user
cp systemd/opencode-usage-review.service systemd/opencode-usage-review.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now opencode-usage-review.timer
```

Reports go to:

```text
~/.local/state/opencode-usage-review/
├── daily/YYYY-MM-DD.md
├── weekly/YYYY-Www.md
├── history/*.json
├── latest.md
├── latest-week.md
├── today.md
├── labels.json
├── done.json
└── logs/YYYY-MM-DD.log
```

The service sets a `PATH` that includes the mise shims. If your Node installation is elsewhere, edit the unit's `Environment=PATH=...` line.

## TUI plugin and agent tools

`plugin/tui.ts` registers:

- `/usage-review` — today's compact report in a local dialog.
- `/usage-week` — the last 7 days.
- `/usage-label` — a 30-second triage flow for the top unlabeled sessions.

`plugin/index.ts` registers two agent tools:

- `outline` — compact symbol outline for Go, TypeScript/JavaScript, Python, Rust, Markdown, and YAML. Go uses `gopls symbols` when available.
- `smart_read` — range-aware read with an unchanged-range cache. Large files return an outline by default; a repeated unchanged range returns "unchanged" unless the session was compacted or `force:true` is passed.

The package has a server part, so add it to `~/.config/opencode/opencode.json`, not `cli.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "plugins": [
    "/home/you/Projects/orchengine-tools/opencode-plugins/opencode-usage-review/plugin"
  ]
}
```

The CLI-only `cli.json` path loads only the TUI part; the server tools require this entry. Restart the TUI after adding it. The dialog runs the CLI with `--text --no-save`; it does not submit a prompt or add tokens to the session.

## History and comparisons

Every `report` run saves a full JSON snapshot under:

```text
~/.local/state/opencode-usage-review/history/
├── day-YYYY-MM-DD.json
└── range-last-7-days-YYYY-MM-DD.json
```

Use `--no-save` for throwaway runs. The TUI passes it automatically.

```bash
node src/cli.ts history list
node src/cli.ts history show day-2026-11-08
node src/cli.ts history compare
node src/cli.ts history compare day-2026-11-08 day-2026-11-07
```

`history compare` with no keys compares the two most recent snapshots of the same kind. It reports changes in quota/list value, active time, activity mix, read amplification, full-file reads, redundant reads, post-compaction repeats, and pre-first-edit share.

## Done items

Save completed work so daily reports and snapshots show what actually shipped:

```bash
node src/cli.ts done add "Migrate authoring to structured workflows" --session ses_abc123 --tag migration
node src/cli.ts done list --days 7
```

Done items appear in the report's **Done** section and are stored in `done.json` next to the labels.


## Improving exploration

The report includes an **Exploration efficiency** section:

- read calls vs unique files (read amplification)
- full-file reads vs ranged reads
- exact range repeats, split into redundant, after-compaction, and after-edit
- grep calls vs unique patterns
- files read then edited vs read but never edited

The first measured run showed the dominant issue was **repeated full-file reads**, not slow search:

- 579 reads across 226 files (2.6x amplification)
- 54% were full-file reads; 38% were truncated
- 73 exact range repeats: 24 redundant, 40 after compaction, 9 after edits
- 143 grep calls but 120 unique patterns, so search itself was not repetitive
- The top repeated reads were `internal/editor/server_test.go` (25 separate ranges), `internal/editor/server.go` (16 reads, 3 exact repeats), `pkg/codegen/source_generation_test.go` (16 ranges), `Makefile` (8 reads, 3 exact repeats), and `pkg/eventschema/descriptor.go` (7 reads, 4 exact repeats)
- The top repeated search was `pipelines` (10 calls), followed by `^diff --git` (5 calls)

That splits the fix into different tools: a symbol/test outline for large files read in many ranges, a read cache for small files read repeatedly, and a symbol search for repeated broad greps.

Priority order:

1. **Use semantic navigation before reading.** For Go, add the `gopls` MCP server. It provides `go_workspace`, `go_search`, `go_file_context`, `go_package_api`, `go_symbol_references`, and `go_diagnostics`, so the agent can find symbols and cross-file dependencies without reading whole files.
2. **Read outlines and ranges, not full files.** 54% of reads were whole files; many were truncated. Ask for the symbol outline first, then read the relevant range.
3. **Do not re-read unchanged ranges.** 24 repeats had no edit and no compaction between them. Use the previous content or an outline instead.
4. **Preserve a working set across compaction.** 40 repeats happened after compaction. A short note listing files, symbols, and decisions is cheaper than re-reading the same files.
5. **Treat search indexing as secondary.** Grep was mostly unique patterns, so a vector or search index is unlikely to be the first win. A symbol index is more targeted.

### `outline` and `smart_read`

The plugin implements both:

- `outline(path)` returns a compact symbol outline with line numbers and a content hash. Go uses `gopls symbols`; TypeScript/JavaScript, Python, Rust, Markdown, and YAML use built-in parsers.
- `smart_read(path, offset?, limit?, mode?, force?)` returns an outline for files over 400 lines by default, returns line-numbered ranges, and caches unchanged ranges per session.
  - A repeated unchanged range returns `cached: true` with no content, unless the session was compacted.
  - After compaction it returns the content once with `compacted: true`.
  - `force: true` bypasses the cache.
  - `mode: "content"` and `mode: "outline"` override the automatic choice.

The OrchEngine exploration policy is a skill at `.opencode/skills/orchengine-exploration/SKILL.md`, listed in `AGENTS.md`. It tells the agent to use gopls MCP, `outline`, and `smart_read` before full-file reads, and to write a working-set note after compaction.

The gopls MCP server is configured per Go project. In this workspace it lives at `.opencode/opencode.json` in OrchEngine:

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "servers": {
      "gopls": {
        "type": "local",
        "command": ["gopls", "mcp"],
        "timeout": { "startup": 60000, "catalog": 60000 }
      }
    }
  }
}
```

Check it with `opencode mcp list`, or `/mcps` in the TUI. The server is project-scoped so non-Go sessions do not pay for its tools or instructions. Add the same block to other Go projects, or move it to the global config if you want it everywhere.

For non-Go code, a tree-sitter or ctags outline tool is the equivalent next step; the measured data does not justify a vector index yet.

## How it computes the numbers

- **Active time**: assistant message spans are merged; gaps up to 10 minutes count as active, longer gaps do not. Overlapping sessions are merged so concurrent work is not double-counted.
- **Forks**: forked sessions copy history. Messages inherited before/through `fork_boundary` are excluded using sequence numbers; only new messages count.
- **Subagents**: their tokens and steps are included, but their time is not added to your attention time.
- **Rework**: redundant reads are the same path/offset/limit read twice with no edit in between; repeated commands are identical shell commands; failed retries are commands repeated after a failure. Exploration efficiency additionally separates exact repeats that happen after compaction (legitimate context loss) from truly redundant repeats.
- **Exploration efficiency**: read amplification is reads divided by unique paths; full-file reads have no offset or limit; repeated grep patterns are calls minus unique patterns.
- **Activity attribution**: each assistant step’s tokens are split equally across its tool calls. A step with no tools is planning. Reads/searches are exploration; shell scripts, analysis commands, and git inspection are analysis; edits before a failure are writing; failed tools/commands and edits after a failure are fixing; tests/lint/build are verification.
- **Command failures**: shell tools report an exit code in metadata. A non-zero exit, or a verification command whose output contains `FAIL`, `panic`, `not ok`, or a compiler/make error, counts as a failure. Successful verification resets the fixing window.
- **Context**: `input + cache.read` per assistant step; p50, p90, and max.
- **Pricing**: per-message list prices, including DeepSeek peak/off-peak and Claude's 100K-context tier. Unknown models are counted as unpriced rather than guessed.

## Tests

```bash
npm test
npm run typecheck
```

The fixture database and temp-file tests cover fork inheritance, overlapping active time, day boundaries, redundant reads, peak pricing, unpriced models, labels, activity attribution, exploration stats, report rendering, history comparison, done items, outlines, and smart-read caching.

## Known limitations

- The OpenCode database schema is internal and can change. `doctor` checks the required tables and columns; the adapter fails loudly instead of silently reporting zero.
- Quota is a live snapshot. Historical quota windows are not stored.
- List value is an estimate, not billed cost.
- Pricing covers the models seen in this workspace; add models in `src/pricing.ts`.
- Activity attribution is heuristic: a step with multiple tools is split equally, and shell command classification is pattern-based. The raw per-session `activities` and `tools` arrays are included in JSON so you can audit the split.
- The TUI dialog is plain text. Markdown files remain the canonical report.

## Privacy

The database is opened with `PRAGMA query_only = ON`. Reports and labels stay under `~/.local/state/opencode-usage-review/`. Reports include session titles and directories; keep the directory private and do not publish reports without review.
