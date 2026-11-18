import { DatabaseSync } from "node:sqlite";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TokenUsage } from "../src/types.ts";

export interface FixtureSession {
  id: string;
  title: string;
  directory?: string;
  parentID?: string;
  forkSessionID?: string;
  forkBoundary?: { type: "before" | "through"; messageID: string };
  idleOutcome?: string;
  timeCreated: number;
  timeUpdated?: number;
}

export interface FixtureMessage {
  id: string;
  sessionID: string;
  type: "user" | "assistant" | "compaction";
  seq: number;
  timeCreated: number;
  data: Record<string, unknown>;
}

export function tokens(
  input: number,
  output: number,
  reasoning = 0,
  cacheRead = 0,
  cacheWrite = 0,
): TokenUsage {
  return { input, output, reasoning, cache: { read: cacheRead, write: cacheWrite } };
}

export function assistantData(options: {
  timeCreated: number;
  timeCompleted?: number;
  model?: string;
  providerID?: string;
  agent?: string;
  usage?: TokenUsage;
  content?: Record<string, unknown>[];
  finish?: string;
  cost?: number;
}): Record<string, unknown> {
  return {
    time: {
      created: options.timeCreated,
      ...(options.timeCompleted ? { completed: options.timeCompleted } : {}),
    },
    agent: options.agent ?? "build",
    model: { id: options.model ?? "deepseek-v4.1-flash", providerID: options.providerID ?? "opencode-go" },
    tokens: options.usage ?? tokens(100, 20, 10, 1000, 0),
    cost: options.cost ?? 0,
    finish: options.finish ?? "tool-calls",
    content: options.content ?? [],
  };
}

export function userData(text: string, timeCreated: number): Record<string, unknown> {
  return { time: { created: timeCreated }, text };
}

export function toolPart(options: {
  id: string;
  name: string;
  input: Record<string, unknown>;
  status?: string;
  output?: string;
  exitCode?: number;
  timeCreated: number;
  timeCompleted?: number;
}): Record<string, unknown> {
  return {
    type: "tool",
    id: options.id,
    name: options.name,
    state: {
      status: options.status ?? "completed",
      input: options.input,
      content: [{ type: "text", text: options.output ?? "" }],
      metadata: options.exitCode === undefined ? {} : { exit: options.exitCode },
      time: {
        created: options.timeCreated,
        ...(options.timeCompleted ? { completed: options.timeCompleted } : {}),
      },
    },
    time: { created: options.timeCreated },
  };
}

export function createFixtureDB(
  sessions: FixtureSession[],
  messages: FixtureMessage[],
): { path: string; directory: string } {
  const directory = mkdtempSync(join(tmpdir(), "opencode-usage-review-"));
  const path = join(directory, "opencode.db");
  const db = new DatabaseSync(path);
  db.exec(`
    CREATE TABLE migration (id TEXT PRIMARY KEY, time_completed INTEGER NOT NULL);
    CREATE TABLE session_v2 (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      directory TEXT NOT NULL,
      parent_id TEXT,
      fork_session_id TEXT,
      fork_boundary TEXT,
      agent TEXT,
      model TEXT,
      idle_outcome TEXT,
      tokens_cache_read INTEGER DEFAULT 0 NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL
    );
    CREATE TABLE session_message (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      type TEXT NOT NULL,
      seq INTEGER NOT NULL,
      time_created INTEGER NOT NULL,
      time_updated INTEGER NOT NULL,
      data TEXT NOT NULL
    );
  `);
  const insertMigration = db.prepare("INSERT INTO migration (id, time_completed) VALUES (?, ?)");
  insertMigration.run("20260510033149_session_usage", 1);
  const insertSession = db.prepare(
    `INSERT INTO session_v2
      (id, title, directory, parent_id, fork_session_id, fork_boundary, agent, model, idle_outcome, time_created, time_updated)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  );
  for (const session of sessions) {
    insertSession.run(
      session.id,
      session.title,
      session.directory ?? "/tmp/project",
      session.parentID ?? null,
      session.forkSessionID ?? null,
      session.forkBoundary ? JSON.stringify(session.forkBoundary) : null,
      "build",
      JSON.stringify({ id: "deepseek-v4.1-flash", providerID: "opencode-go" }),
      session.idleOutcome ?? "succeeded",
      session.timeCreated,
      session.timeUpdated ?? session.timeCreated,
    );
  }
  const insertMessage = db.prepare(
    `INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
  );
  for (const message of messages) {
    insertMessage.run(
      message.id,
      message.sessionID,
      message.type,
      message.seq,
      message.timeCreated,
      message.timeCreated,
      JSON.stringify(message.data),
    );
  }
  db.close();
  return { path, directory };
}
