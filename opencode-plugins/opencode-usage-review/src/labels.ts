import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { SessionLabel } from "./types.ts";

export type LabelOutcome = SessionLabel["outcome"];

const OUTCOMES: LabelOutcome[] = ["useful", "rework", "abandoned", "explore"];

interface LabelFile {
  version: 1;
  sessions: Record<string, SessionLabel>;
}

function stateHome(): string {
  return process.env["XDG_STATE_HOME"] ?? join(homedir(), ".local", "state");
}

export function labelsPath(): string {
  return join(stateHome(), "opencode-usage-review", "labels.json");
}

export function isLabelOutcome(value: string): value is LabelOutcome {
  return OUTCOMES.includes(value as LabelOutcome);
}

export async function loadLabels(): Promise<Record<string, SessionLabel>> {
  try {
    const text = await readFile(labelsPath(), "utf8");
    const parsed = JSON.parse(text) as Partial<LabelFile>;
    if (parsed.version !== 1 || !parsed.sessions) return {};
    return parsed.sessions;
  } catch {
    return {};
  }
}

export async function saveLabels(sessions: Record<string, SessionLabel>): Promise<void> {
  const path = labelsPath();
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const payload: LabelFile = { version: 1, sessions };
  const temporary = `${path}.tmp`;
  await writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

export async function setLabel(
  sessionID: string,
  outcome: LabelOutcome,
  note?: string,
  taskType?: string,
): Promise<SessionLabel> {
  const labels = await loadLabels();
  const label: SessionLabel = {
    outcome,
    ...(note ? { note } : {}),
    ...(taskType ? { taskType } : {}),
    updatedAt: Date.now(),
  };
  labels[sessionID] = label;
  await saveLabels(labels);
  return label;
}

export async function removeLabel(sessionID: string): Promise<boolean> {
  const labels = await loadLabels();
  if (!labels[sessionID]) return false;
  delete labels[sessionID];
  await saveLabels(labels);
  return true;
}
