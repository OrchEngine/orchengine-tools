#!/usr/bin/env node
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { addDone, listDone } from "./done.ts";
import {
  listSnapshots,
  loadSnapshot,
  renderComparison,
  saveSnapshot,
} from "./history.ts";
import { loadDatabase, inspectSchema, openReadOnly, resolveDBPath } from "./db.ts";
import { isLabelOutcome, labelsPath, loadLabels, removeLabel, setLabel } from "./labels.ts";
import { buildReport } from "./metrics.ts";
import { pricesFor, promptTokens } from "./pricing.ts";
import { loadQuota } from "./quota.ts";
import { renderJSON, renderMarkdown, renderText } from "./report.ts";
import { formatDateTime, formatDuration, formatMoney, lastDaysRange, localDayRange } from "./time.ts";
import type { ReportData } from "./types.ts";

interface ParsedArgs {
  positional: string[];
  flags: Record<string, string | true>;
}

function parseArgs(argv: string[]): ParsedArgs {
  const positional: string[] = [];
  const flags: Record<string, string | true> = {};
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (!arg) continue;
    if (arg === "--") {
      positional.push(...argv.slice(index + 1));
      break;
    }
    if (!arg.startsWith("--")) {
      positional.push(arg);
      continue;
    }
    const body = arg.slice(2);
    const equals = body.indexOf("=");
    if (equals >= 0) {
      flags[body.slice(0, equals)] = body.slice(equals + 1);
      continue;
    }
    const next = argv[index + 1];
    if (next && !next.startsWith("--")) {
      flags[body] = next;
      index += 1;
    } else {
      flags[body] = true;
    }
  }
  return { positional, flags };
}

function stringFlag(flags: Record<string, string | true>, name: string): string | undefined {
  const value = flags[name];
  return typeof value === "string" ? value : undefined;
}

function booleanFlag(flags: Record<string, string | true>, name: string): boolean {
  return flags[name] === true;
}

function printHelp(): void {
  console.log(`opencode-usage-review — daily AI usage review for OpenCode

Usage:
  opencode-usage-review report [--day today|yesterday|YYYY-MM-DD] [--json] [--out FILE]
  opencode-usage-review report --days 7 [--json] [--out FILE]
  opencode-usage-review week
  opencode-usage-review labels list
  opencode-usage-review labels set <session-id> useful|rework|abandoned|explore [--note TEXT] [--task TYPE]
  opencode-usage-review labels remove <session-id>
  opencode-usage-review done add <text> [--session ID] [--tag TAG]
  opencode-usage-review done list [--days N]
  opencode-usage-review history list
  opencode-usage-review history show <key>
  opencode-usage-review history compare [current-key] [previous-key]
  opencode-usage-review doctor

Options:
  --db PATH       OpenCode database (default: ~/.local/share/opencode/opencode.db)
  --no-quota      Skip the opencode-quota lookup
  --no-save       Do not write a history snapshot
  --json          Print structured JSON instead of Markdown
  --text          Print a compact plain-text summary for the TUI dialog
  --out FILE      Write the report to FILE as well as stdout

Reports are saved to ~/.local/state/opencode-usage-review/history/ by default.
Quota is read from opencode-quota's JSON export or its terminal command when available.
Reports and labels stay local. The OpenCode database is opened read-only.`);
}

async function commandReport(args: ParsedArgs): Promise<void> {
  const daysFlag = stringFlag(args.flags, "days");
  const dayFlag = stringFlag(args.flags, "day") ?? "today";
  if (daysFlag && stringFlag(args.flags, "day")) {
    throw new Error("Use either --day or --days, not both.");
  }
  const range = daysFlag
    ? lastDaysRange(Number(daysFlag))
    : localDayRange(dayFlag);
  if (daysFlag && !Number.isInteger(Number(daysFlag))) {
    throw new Error("--days must be an integer.");
  }
  const noQuota = booleanFlag(args.flags, "no-quota");
  const quota = noQuota ? [] : await loadQuota();
  const labels = await loadLabels();
  const report = buildReport({
    ...(stringFlag(args.flags, "db") ? { dbPath: stringFlag(args.flags, "db") } : {}),
    range,
    quota,
    labels,
  });
  report.done = await listDone(range);
  if (!booleanFlag(args.flags, "no-save")) {
    const saved = await saveSnapshot(report);
    process.stderr.write(`saved ${saved.key} -> ${saved.path}\n`);
  }
  const output = booleanFlag(args.flags, "json")
    ? renderJSON(report)
    : booleanFlag(args.flags, "text")
      ? renderText(report)
      : renderMarkdown(report);
  const out = stringFlag(args.flags, "out");
  if (out) {
    const path = resolve(out);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, output, { mode: 0o600 });
  }
  process.stdout.write(output);
}

function printLabel(report: ReportData, sessionID: string): void {
  const label = report.labels[sessionID];
  if (!label) {
    console.log(`${sessionID}: unlabeled`);
    return;
  }
  console.log(`${sessionID}: ${label.outcome}${label.taskType ? ` · ${label.taskType}` : ""}`);
  if (label.note) console.log(`  ${label.note}`);
}

async function commandLabels(args: ParsedArgs): Promise<void> {
  const subcommand = args.positional[1] ?? "list";
  if (subcommand === "set") {
    const sessionID = args.positional[2];
    const outcome = args.positional[3];
    if (!sessionID || !outcome) {
      throw new Error("Usage: labels set <session-id> useful|rework|abandoned|explore");
    }
    if (!isLabelOutcome(outcome)) {
      throw new Error("Outcome must be useful, rework, abandoned, or explore.");
    }
    const note = stringFlag(args.flags, "note");
    const taskType = stringFlag(args.flags, "task");
    const label = await setLabel(sessionID, outcome, note, taskType);
    console.log(`${sessionID}: ${label.outcome}${label.note ? ` · ${label.note}` : ""}`);
    return;
  }
  if (subcommand === "remove") {
    const sessionID = args.positional[2];
    if (!sessionID) throw new Error("Usage: labels remove <session-id>");
    const removed = await removeLabel(sessionID);
    console.log(removed ? `${sessionID}: removed` : `${sessionID}: no label`);
    return;
  }
  if (subcommand !== "list") {
    throw new Error(`Unknown labels subcommand "${subcommand}".`);
  }
  const labels = await loadLabels();
  const entries = Object.entries(labels);
  if (entries.length === 0) {
    console.log("No labels yet.");
    return;
  }
  const report = buildReport({
    ...(stringFlag(args.flags, "db") ? { dbPath: stringFlag(args.flags, "db") } : {}),
    range: lastDaysRange(365),
    quota: [],
    labels,
  });
  for (const [sessionID] of entries) printLabel(report, sessionID);
}

async function commandDoctor(args: ParsedArgs): Promise<void> {
  const dbPath = resolveDBPath(stringFlag(args.flags, "db"));
  const db = openReadOnly(dbPath);
  try {
    const schema = inspectSchema(db);
    const loaded = loadDatabase(db);
    const assistantCount = loaded.sessions.reduce(
      (total, session) =>
        total + session.messages.filter((message) => message.kind === "assistant").length,
      0,
    );
    const models = new Map<string, number>();
    let unpriced = 0;
    let unresolvedForks = 0;
    for (const session of loaded.sessions) {
      if (session.row.forkSessionID && session.boundarySeq === undefined) unresolvedForks += 1;
      for (const message of session.messages) {
        if (message.kind !== "assistant") continue;
        models.set(message.model.id, (models.get(message.model.id) ?? 0) + 1);
        if (pricesFor(message.model, message.timeCreated, promptTokens(message)) === undefined) {
          unpriced += 1;
        }
      }
    }
    console.log(`Database: ${dbPath}`);
    console.log(`Schema: ${schema.hasSessions && schema.hasMessages ? "supported" : "unsupported"}`);
    console.log(`Migrations: ${schema.migrations.at(-1) ?? "none"}`);
    console.log(`Sessions: ${loaded.sessions.length}`);
    console.log(`Assistant messages: ${assistantCount}`);
    console.log(
      `Models: ${[...models.entries()].map(([model, count]) => `${model} (${count})`).join(", ") || "none"}`,
    );
    console.log(`Pricing: ${unpriced === 0 ? "all messages priced" : `${unpriced} unpriced messages`}`);
    console.log(`Fork boundaries: ${unresolvedForks === 0 ? "resolved" : `${unresolvedForks} unresolved`}`);
    console.log(`Labels: ${labelsPath()}`);
    const quota = booleanFlag(args.flags, "no-quota") ? [] : await loadQuota();
    console.log(
      `Quota: ${quota.length > 0 ? quota.map((snapshot) => `${snapshot.provider} (${snapshot.windows.length} windows)`).join(", ") : "unavailable"}`,
    );
  } finally {
    db.close();
  }
}

async function commandHistory(args: ParsedArgs): Promise<void> {
  const subcommand = args.positional[1] ?? "list";
  if (subcommand === "list") {
    const entries = await listSnapshots();
    if (entries.length === 0) {
      console.log("No history snapshots yet.");
      return;
    }
    console.log("KEY                                      RANGE                 GENERATED            SESSIONS  LIST $   ACTIVE");
    for (const entry of entries) {
      console.log(
        `${entry.key.padEnd(40)} ${entry.label.padEnd(20)} ${new Date(entry.generatedAt).toLocaleString().padEnd(20)} ${String(entry.sessions).padStart(8)}  ${formatMoney(entry.listCost).padStart(7)}  ${formatDuration(entry.activeMs).padStart(6)}`,
      );
    }
    return;
  }
  if (subcommand === "show") {
    const key = args.positional[2];
    if (!key) throw new Error("Usage: history show <key>");
    const report = await loadSnapshot(key);
    process.stdout.write(renderMarkdown(report));
    return;
  }
  if (subcommand === "compare") {
    const entries = await listSnapshots();
    let currentKey = args.positional[2];
    let previousKey = args.positional[3];
    if (!currentKey) currentKey = entries[0]?.key;
    if (!currentKey) throw new Error("No history snapshots to compare.");
    if (!previousKey) {
      const kind = currentKey.startsWith("day-") ? "day" : "range";
      const currentEntry = entries.find((entry) => entry.key === currentKey);
      previousKey = entries.find(
        (entry) =>
          entry.key !== currentKey &&
          (entry.key.startsWith("day-") ? "day" : "range") === kind &&
          (!currentEntry || entry.to < currentEntry.to),
      )?.key;
    }
    if (!previousKey) throw new Error("No earlier snapshot of the same kind to compare against.");
    const current = await loadSnapshot(currentKey);
    const previous = await loadSnapshot(previousKey);
    process.stdout.write(renderComparison(current, previous));
    return;
  }
  throw new Error(`Unknown history subcommand "${subcommand}".`);
}

async function commandDone(args: ParsedArgs): Promise<void> {
  const subcommand = args.positional[1] ?? "list";
  if (subcommand === "add") {
    const text = args.positional.slice(2).join(" ").trim();
    if (!text) throw new Error("Usage: done add <text> [--session ID] [--tag TAG]");
    const sessionID = stringFlag(args.flags, "session");
    const tag = stringFlag(args.flags, "tag");
    const item = await addDone(text, {
      ...(sessionID ? { sessionID } : {}),
      ...(tag ? { tags: [tag] } : {}),
    });
    console.log(`${item.id}: ${item.text}`);
    return;
  }
  if (subcommand === "list") {
    const daysFlag = stringFlag(args.flags, "days") ?? "30";
    const range = lastDaysRange(Number(daysFlag));
    const items = await listDone(range);
    if (items.length === 0) {
      console.log("No done items in this range.");
      return;
    }
    for (const item of items) {
      const session = item.sessionID ? `  (${item.sessionID})` : "";
      console.log(`${formatDateTime(item.createdAt)}  ${item.text}${session}`);
    }
    return;
  }
  throw new Error(`Unknown done subcommand "${subcommand}".`);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (booleanFlag(args.flags, "help") || booleanFlag(args.flags, "h")) {
    printHelp();
    return;
  }
  const command = args.positional[0] ?? "report";
  if (command === "report") {
    await commandReport(args);
    return;
  }
  if (command === "week") {
    await commandReport({ ...args, flags: { ...args.flags, days: "7" } });
    return;
  }
  if (command === "labels") {
    await commandLabels(args);
    return;
  }
  if (command === "done") {
    await commandDone(args);
    return;
  }
  if (command === "history") {
    await commandHistory(args);
    return;
  }
  if (command === "doctor") {
    await commandDoctor(args);
    return;
  }
  throw new Error(`Unknown command "${command}". Run with --help for usage.`);
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`error: ${message}`);
  process.exitCode = 1;
});
