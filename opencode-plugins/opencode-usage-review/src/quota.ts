import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { QuotaSnapshot, QuotaWindow } from "./types.ts";

const execFileAsync = promisify(execFile);

interface RawQuotaEntry {
  id?: unknown;
  name?: unknown;
  window?: unknown;
  resetAt?: unknown;
  renderType?: unknown;
  percentRemaining?: unknown;
}

interface RawQuotaProvider {
  status?: unknown;
  fetchedAt?: unknown;
  entries?: unknown;
}

interface RawQuotaExport {
  providers?: unknown;
}

function exportPath(): string {
  const cacheHome = process.env["XDG_CACHE_HOME"] ?? join(homedir(), ".cache");
  return join(cacheHome, "opencode", "quota-export.json");
}

function parseSnapshot(payload: RawQuotaExport): QuotaSnapshot[] {
  const providers = payload.providers;
  if (!providers || typeof providers !== "object") return [];
  const snapshots: QuotaSnapshot[] = [];
  for (const [providerID, rawProvider] of Object.entries(providers)) {
    const provider = rawProvider as RawQuotaProvider;
    if (provider.status !== "ok" || !Array.isArray(provider.entries)) continue;
    const windows: QuotaWindow[] = [];
    for (const rawEntry of provider.entries as RawQuotaEntry[]) {
      if (rawEntry.renderType !== "percent") continue;
      if (typeof rawEntry.percentRemaining !== "number") continue;
      const key = typeof rawEntry.id === "string" ? rawEntry.id : "unknown";
      const label = typeof rawEntry.name === "string" ? rawEntry.name : key;
      const resetAt =
        typeof rawEntry.resetAt === "number" ? rawEntry.resetAt * 1000 : undefined;
      windows.push({
        key,
        label,
        percentRemaining: rawEntry.percentRemaining,
        ...(resetAt ? { resetAt } : {}),
      });
    }
    if (windows.length === 0) continue;
    snapshots.push({
      provider: providerID,
      ...(typeof provider.fetchedAt === "number" ? { fetchedAt: provider.fetchedAt * 1000 } : {}),
      windows,
    });
  }
  return snapshots;
}

async function readExportFile(): Promise<QuotaSnapshot[]> {
  try {
    const text = await readFile(exportPath(), "utf8");
    return parseSnapshot(JSON.parse(text) as RawQuotaExport);
  } catch {
    return [];
  }
}

async function runQuotaCli(): Promise<QuotaSnapshot[]> {
  try {
    const { stdout } = await execFileAsync(
      "npx",
      ["--yes", "@slkiser/opencode-quota@latest", "show", "--json"],
      { timeout: 30_000, maxBuffer: 10 * 1024 * 1024 },
    );
    return parseSnapshot(JSON.parse(stdout) as RawQuotaExport);
  } catch {
    return [];
  }
}

export async function loadQuota(): Promise<QuotaSnapshot[]> {
  if (process.env["OPENCODE_USAGE_REVIEW_NO_QUOTA"] === "1") return [];
  const fromFile = await readExportFile();
  if (fromFile.length > 0) return fromFile;
  return runQuotaCli();
}
