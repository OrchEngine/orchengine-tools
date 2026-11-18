import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { formatDuration, formatMoney, formatPercent, localDayKey } from "./time.ts";
import type { ReportData } from "./types.ts";

interface SnapshotFile {
  version: 1;
  key: string;
  report: ReportData;
}

export interface HistoryEntry {
  key: string;
  label: string;
  from: number;
  to: number;
  generatedAt: number;
  sessions: number;
  listCost: number;
  activeMs: number;
}

type ComparisonUnit = "money" | "duration" | "share" | "count" | "ratio";

export interface ComparisonRow {
  label: string;
  current: number;
  previous: number;
  unit: ComparisonUnit;
}

function stateHome(): string {
  return process.env["XDG_STATE_HOME"] ?? join(homedir(), ".local", "state");
}

export function historyDir(): string {
  return join(stateHome(), "opencode-usage-review", "history");
}

function slug(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function snapshotKey(report: ReportData): string {
  if (report.day && /^\d{4}-\d{2}-\d{2}$/.test(report.day)) {
    return `day-${report.day}`;
  }
  const label = slug(report.day ?? "range");
  const end = localDayKey(Math.max(report.from, report.to - 1));
  return `range-${label}-${end}`;
}

export async function saveSnapshot(report: ReportData): Promise<{ key: string; path: string }> {
  const key = snapshotKey(report);
  const path = join(historyDir(), `${key}.json`);
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const payload: SnapshotFile = { version: 1, key, report };
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
  return { key, path };
}

export async function listSnapshots(): Promise<HistoryEntry[]> {
  let files: string[];
  try {
    files = await readdir(historyDir());
  } catch {
    return [];
  }
  const entries: HistoryEntry[] = [];
  for (const file of files) {
    if (!file.endsWith(".json")) continue;
    try {
      const text = await readFile(join(historyDir(), file), "utf8");
      const parsed = JSON.parse(text) as Partial<SnapshotFile>;
      if (parsed.version !== 1 || !parsed.report || typeof parsed.key !== "string") continue;
      const report = parsed.report;
      entries.push({
        key: parsed.key,
        label: report.day ?? "range",
        from: report.from,
        to: report.to,
        generatedAt: report.generatedAt,
        sessions: report.totals.sessions,
        listCost: report.totals.listCost,
        activeMs: report.totals.activeMs,
      });
    } catch {
      // Ignore a corrupt snapshot instead of hiding the rest of the history.
    }
  }
  return entries.sort((left, right) => right.to - left.to || right.generatedAt - left.generatedAt);
}

export async function loadSnapshot(key: string): Promise<ReportData> {
  const text = await readFile(join(historyDir(), `${key}.json`), "utf8");
  const parsed = JSON.parse(text) as Partial<SnapshotFile>;
  if (parsed.version !== 1 || !parsed.report) {
    throw new Error(`Snapshot ${key} has an unsupported format.`);
  }
  return parsed.report;
}

function activityCost(report: ReportData, key: string): number {
  return report.activities.find((activity) => activity.key === key)?.listCost ?? 0;
}

function share(report: ReportData, key: string): number {
  if (report.totals.listCost <= 0) return 0;
  return activityCost(report, key) / report.totals.listCost;
}

function editingCost(report: ReportData): number {
  return report.sessions
    .filter((session) => session.hasEdit)
    .reduce((sum, session) => sum + session.listCost, 0);
}

export function compareReports(current: ReportData, previous: ReportData): ComparisonRow[] {
  const currentEditing = editingCost(current);
  const previousEditing = editingCost(previous);
  return [
    { label: "List value", current: current.totals.listCost, previous: previous.totals.listCost, unit: "money" },
    { label: "Active time", current: current.totals.activeMs, previous: previous.totals.activeMs, unit: "duration" },
    { label: "Sessions", current: current.totals.sessions, previous: previous.totals.sessions, unit: "count" },
    { label: "Prompts", current: current.totals.userTurns, previous: previous.totals.userTurns, unit: "count" },
    { label: "Steps", current: current.totals.steps, previous: previous.totals.steps, unit: "count" },
    { label: "Understanding share", current: share(current, "exploration") + share(current, "analysis"), previous: share(previous, "exploration") + share(previous, "analysis"), unit: "share" },
    { label: "Writing share", current: share(current, "writing"), previous: share(previous, "writing"), unit: "share" },
    { label: "Fixing + verification share", current: share(current, "fixing") + share(current, "verification"), previous: share(previous, "fixing") + share(previous, "verification"), unit: "share" },
    { label: "Planning share", current: share(current, "planning"), previous: share(previous, "planning"), unit: "share" },
    { label: "Read amplification", current: current.exploration.readAmplification, previous: previous.exploration.readAmplification, unit: "ratio" },
    { label: "Full-file read share", current: current.exploration.readCalls > 0 ? current.exploration.fullFileReads / current.exploration.readCalls : 0, previous: previous.exploration.readCalls > 0 ? previous.exploration.fullFileReads / previous.exploration.readCalls : 0, unit: "share" },
    { label: "Exact read repeats", current: current.exploration.exactRepeats, previous: previous.exploration.exactRepeats, unit: "count" },
    { label: "Redundant read repeats", current: current.exploration.redundantRepeats, previous: previous.exploration.redundantRepeats, unit: "count" },
    { label: "Post-compaction repeats", current: current.exploration.postCompactionRepeats, previous: previous.exploration.postCompactionRepeats, unit: "count" },
    { label: "Pre-first-edit share", current: currentEditing > 0 ? current.totals.preEditCost / currentEditing : 0, previous: previousEditing > 0 ? previous.totals.preEditCost / previousEditing : 0, unit: "share" },
  ];
}

function formatValue(value: number, unit: ComparisonUnit): string {
  if (unit === "money") return formatMoney(value);
  if (unit === "duration") return formatDuration(value);
  if (unit === "share") return formatPercent(value);
  if (unit === "ratio") return `${value.toFixed(1)}x`;
  return String(Math.round(value));
}

function formatDelta(current: number, previous: number, unit: ComparisonUnit): string {
  const delta = current - previous;
  if (unit === "share") {
    const points = Math.round(delta * 100);
    return `${points >= 0 ? "+" : ""}${points}pp`;
  }
  if (unit === "ratio") {
    if (Math.abs(delta) < 0.05) return "0.0x";
    return `${delta >= 0 ? "+" : "-"}${Math.abs(delta).toFixed(1)}x`;
  }
  if (unit === "count") {
    return `${delta >= 0 ? "+" : ""}${Math.round(delta)}`;
  }
  if (unit === "money") {
    const percent = previous > 0 ? (delta / previous) * 100 : 0;
    return `${delta >= 0 ? "+" : "-"}${formatMoney(Math.abs(delta))} (${percent >= 0 ? "+" : ""}${percent.toFixed(1)}%)`;
  }
  const percent = previous > 0 ? (delta / previous) * 100 : 0;
  return `${delta >= 0 ? "+" : ""}${formatDuration(delta)} (${percent >= 0 ? "+" : ""}${percent.toFixed(1)}%)`;
}

export function renderComparison(current: ReportData, previous: ReportData): string {
  const rows = compareReports(current, previous);
  const lines = [
    "# Usage comparison",
    "",
    `Current: **${current.day ?? "range"}** (${new Date(current.to - 1).toLocaleDateString()})`,
    `Previous: **${previous.day ?? "range"}** (${new Date(previous.to - 1).toLocaleDateString()})`,
    "",
    "| Metric | Current | Previous | Delta |",
    "| --- | ---: | ---: | ---: |",
  ];
  for (const row of rows) {
    lines.push(
      `| ${row.label} | ${formatValue(row.current, row.unit)} | ${formatValue(row.previous, row.unit)} | ${formatDelta(row.current, row.previous, row.unit)} |`,
    );
  }
  if (current.to > current.generatedAt) {
    lines.push("", "_Current snapshot covers a partial range; compare with the previous full period cautiously._");
  }
  lines.push("");
  return lines.join("\n");
}
