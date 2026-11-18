import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { DoneItem } from "./types.ts";

interface DoneFile {
  version: 1;
  items: DoneItem[];
}

function stateHome(): string {
  return process.env["XDG_STATE_HOME"] ?? join(homedir(), ".local", "state");
}

export function donePath(): string {
  return join(stateHome(), "opencode-usage-review", "done.json");
}

function newID(timestamp: number): string {
  return `done_${timestamp.toString(36)}_${Math.random().toString(36).slice(2, 8)}`;
}

async function loadDoneFile(): Promise<DoneItem[]> {
  try {
    const text = await readFile(donePath(), "utf8");
    const parsed = JSON.parse(text) as Partial<DoneFile>;
    if (parsed.version !== 1 || !Array.isArray(parsed.items)) return [];
    return parsed.items;
  } catch {
    return [];
  }
}

async function saveDoneFile(items: DoneItem[]): Promise<void> {
  const path = donePath();
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const payload: DoneFile = { version: 1, items };
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

export async function addDone(
  text: string,
  options: { sessionID?: string; tags?: string[] } = {},
): Promise<DoneItem> {
  const createdAt = Date.now();
  const item: DoneItem = {
    id: newID(createdAt),
    createdAt,
    text,
    ...(options.sessionID ? { sessionID: options.sessionID } : {}),
    tags: options.tags ?? [],
  };
  const items = await loadDoneFile();
  items.push(item);
  items.sort((left, right) => left.createdAt - right.createdAt);
  await saveDoneFile(items);
  return item;
}

export async function listDone(range?: { from: number; to: number }): Promise<DoneItem[]> {
  const items = await loadDoneFile();
  if (!range) return items;
  return items.filter(
    (item) => item.createdAt >= range.from && item.createdAt < range.to,
  );
}
