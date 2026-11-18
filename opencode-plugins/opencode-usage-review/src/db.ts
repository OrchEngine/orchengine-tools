import { DatabaseSync } from "node:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";
import type {
  AssistantMessage,
  ForkBoundary,
  LoadedSession,
  ModelRef,
  SessionMessage,
  SessionRow,
  TokenUsage,
  ToolCall,
  UserMessage,
} from "./types.ts";

const EMPTY_TOKENS: TokenUsage = {
  input: 0,
  output: 0,
  reasoning: 0,
  cache: { read: 0, write: 0 },
};

function expandHome(path: string): string {
  if (path === "~") return homedir();
  if (path.startsWith("~/")) return join(homedir(), path.slice(2));
  return path;
}

export function resolveDBPath(explicit?: string): string {
  if (explicit) return expandHome(explicit);
  const fromEnv = process.env["OPENCODE_DB"];
  if (fromEnv) return expandHome(fromEnv);
  return join(homedir(), ".local", "share", "opencode", "opencode.db");
}

export function openReadOnly(path: string): DatabaseSync {
  const db = new DatabaseSync(path, { readOnly: true });
  db.exec("PRAGMA query_only = ON;");
  db.exec("PRAGMA busy_timeout = 5000;");
  return db;
}

export interface SchemaInfo {
  migrations: string[];
  hasSessions: boolean;
  hasMessages: boolean;
  sessionColumns: Set<string>;
}

export function inspectSchema(db: DatabaseSync): SchemaInfo {
  const tables = new Set(
    db
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all()
      .map((row) => String((row as { name: unknown }).name)),
  );
  const migrations = tables.has("migration")
    ? db
        .prepare("SELECT id FROM migration ORDER BY id")
        .all()
        .map((row) => String((row as { id: unknown }).id))
    : [];
  const sessionColumns = tables.has("session_v2")
    ? new Set(
        db
          .prepare("PRAGMA table_info(session_v2)")
          .all()
          .map((row) => String((row as { name: unknown }).name)),
      )
    : new Set<string>();
  return {
    migrations,
    hasSessions: tables.has("session_v2"),
    hasMessages: tables.has("session_message"),
    sessionColumns,
  };
}

export function assertSupportedSchema(schema: SchemaInfo): void {
  if (!schema.hasSessions || !schema.hasMessages) {
    throw new Error(
      "Unsupported OpenCode database: expected session_v2 and session_message tables.",
    );
  }
  const required = [
    "id",
    "title",
    "directory",
    "time_created",
    "time_updated",
    "tokens_cache_read",
  ];
  const missing = required.filter((column) => !schema.sessionColumns.has(column));
  if (missing.length > 0) {
    throw new Error(`Unsupported OpenCode session schema: missing ${missing.join(", ")}.`);
  }
}

function parseJSON<T>(value: unknown): T | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  try {
    return JSON.parse(value) as T;
  } catch {
    return undefined;
  }
}

function numberValue(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function stringValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function parseModel(value: unknown): ModelRef | undefined {
  const parsed = parseJSON<ModelRef>(value);
  if (!parsed || typeof parsed.id !== "string") return undefined;
  return parsed;
}

function parseForkBoundary(value: unknown): ForkBoundary | undefined {
  const parsed = parseJSON<ForkBoundary>(value);
  if (!parsed || typeof parsed.messageID !== "string") return undefined;
  if (parsed.type !== "before" && parsed.type !== "through") return undefined;
  return parsed;
}

function loadSessionRows(db: DatabaseSync): SessionRow[] {
  const rows = db
    .prepare(
      `SELECT id, title, directory, parent_id, fork_session_id, fork_boundary,
              agent, model, idle_outcome, time_created, time_updated
       FROM session_v2`,
    )
    .all();
  return rows.map((row) => {
    const record = row as Record<string, unknown>;
    return {
      id: stringValue(record["id"]),
      title: stringValue(record["title"]),
      directory: stringValue(record["directory"]),
      parentID: stringValue(record["parent_id"]) || undefined,
      forkSessionID: stringValue(record["fork_session_id"]) || undefined,
      forkBoundary: parseForkBoundary(record["fork_boundary"]),
      agent: stringValue(record["agent"]) || undefined,
      model: parseModel(record["model"]),
      idleOutcome: stringValue(record["idle_outcome"]) || undefined,
      timeCreated: numberValue(record["time_created"]),
      timeUpdated: numberValue(record["time_updated"]),
    };
  });
}

interface RawMessageRow {
  id: string;
  session_id: string;
  type: string;
  seq: number;
  time_created: number;
  data: string;
}

function parseToolCall(part: Record<string, unknown>, fallbackTime: number): ToolCall | undefined {
  if (part["type"] !== "tool") return undefined;
  const name = stringValue(part["name"]);
  if (!name) return undefined;
  const state = (part["state"] ?? {}) as Record<string, unknown>;
  const time = (state["time"] ?? {}) as Record<string, unknown>;
  const input = (state["input"] ?? {}) as Record<string, unknown>;
  const metadata = (state["metadata"] ?? {}) as Record<string, unknown>;
  const exit = metadata["exit"];
  const truncated = metadata["truncated"];
  return {
    id: stringValue(part["id"]),
    name,
    status: stringValue(state["status"]),
    input,
    outputText: toolOutputText(state["content"]),
    ...(typeof exit === "number" ? { exitCode: exit } : {}),
    ...(typeof truncated === "boolean" ? { truncated } : {}),
    timeCreated: numberValue(time["created"]) || fallbackTime,
    timeRan: numberValue(time["ran"]) || undefined,
    timeCompleted: numberValue(time["completed"]) || undefined,
  };
}

function toolOutputText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((part) => {
        if (typeof part === "string") return part;
        if (part && typeof part === "object") {
          const record = part as Record<string, unknown>;
          return stringValue(record["text"]);
        }
        return "";
      })
      .join("\n");
  }
  if (content && typeof content === "object") {
    return stringValue((content as Record<string, unknown>)["text"]);
  }
  return "";
}

function parseMessage(row: RawMessageRow): SessionMessage | undefined {
  const data = parseJSON<Record<string, unknown>>(row.data);
  if (!data) return undefined;
  const time = (data["time"] ?? {}) as Record<string, unknown>;
  const timeCreated = numberValue(time["created"]) || row.time_created;
  const base = {
    id: row.id,
    sessionID: row.session_id,
    seq: row.seq,
    timeCreated,
  };

  if (row.type === "assistant") {
    const tokens = (data["tokens"] ?? {}) as Record<string, unknown>;
    const cache = (tokens["cache"] ?? {}) as Record<string, unknown>;
    const content = Array.isArray(data["content"]) ? data["content"] : [];
    const toolCalls: ToolCall[] = [];
    let textChars = 0;
    let reasoningChars = 0;
    for (const rawPart of content) {
      if (!rawPart || typeof rawPart !== "object") continue;
      const part = rawPart as Record<string, unknown>;
      if (part["type"] === "text") textChars += stringValue(part["text"]).length;
      if (part["type"] === "reasoning") reasoningChars += stringValue(part["text"]).length;
      const tool = parseToolCall(part, timeCreated);
      if (tool) toolCalls.push(tool);
    }
    const message: AssistantMessage = {
      kind: "assistant",
      ...base,
      agent: stringValue(data["agent"]),
      model: parseModel(JSON.stringify(data["model"])) ?? {
        id: "unknown",
        providerID: "unknown",
      },
      tokens: {
        input: numberValue(tokens["input"]),
        output: numberValue(tokens["output"]),
        reasoning: numberValue(tokens["reasoning"]),
        cache: {
          read: numberValue(cache["read"]),
          write: numberValue(cache["write"]),
        },
      },
      cost: numberValue(data["cost"]),
      finish: stringValue(data["finish"]) || undefined,
      toolCalls,
      textChars,
      reasoningChars,
    };
    const completed = numberValue(time["completed"]);
    if (completed > 0) message.timeCompleted = completed;
    return message;
  }

  if (row.type === "user") {
    const message: UserMessage = {
      kind: "user",
      ...base,
      text: stringValue(data["text"]),
    };
    return message;
  }

  if (row.type === "compaction") {
    return { kind: "compaction", ...base };
  }

  return { kind: "other", ...base, type: row.type };
}

function loadMessages(db: DatabaseSync): RawMessageRow[] {
  return db
    .prepare(
      `SELECT id, session_id, type, seq, time_created, data
       FROM session_message
       ORDER BY session_id, seq`,
    )
    .all() as unknown as RawMessageRow[];
}

function boundarySequence(
  session: SessionRow,
  parentMessages: SessionMessage[],
  ownMessages: SessionMessage[],
): number | undefined {
  const boundary = session.forkBoundary;
  if (!boundary) return undefined;
  const parentMatch = parentMessages.find((message) => message.id === boundary.messageID);
  if (parentMatch) return parentMatch.seq;
  const ownMatch = ownMessages.find((message) => message.id === boundary.messageID);
  if (ownMatch) return ownMatch.seq;
  const suffix = /_(\d+)$/.exec(boundary.messageID);
  if (suffix) return Number(suffix[1]);
  return undefined;
}

export interface LoadedDatabase {
  sessions: LoadedSession[];
  schema: SchemaInfo;
}

export function loadDatabase(db: DatabaseSync): LoadedDatabase {
  const schema = inspectSchema(db);
  assertSupportedSchema(schema);
  const rows = loadSessionRows(db);
  const messagesBySession = new Map<string, SessionMessage[]>();
  for (const raw of loadMessages(db)) {
    const message = parseMessage(raw);
    if (!message) continue;
    const list = messagesBySession.get(raw.session_id) ?? [];
    list.push(message);
    messagesBySession.set(raw.session_id, list);
  }

  const sessionByID = new Map(rows.map((row) => [row.id, row]));
  const sessions: LoadedSession[] = [];
  for (const row of rows) {
    const allMessages = messagesBySession.get(row.id) ?? [];
    const parentMessages = row.forkSessionID
      ? [...(messagesBySession.get(row.forkSessionID) ?? [])]
      : [];
    const boundary = row.forkSessionID
      ? boundarySequence(row, parentMessages, allMessages)
      : undefined;
    let inherited = 0;
    let messages = allMessages;
    if (row.forkSessionID && row.forkBoundary && boundary !== undefined) {
      messages = allMessages.filter((message) => {
        const isInherited =
          row.forkBoundary?.type === "before"
            ? message.seq < boundary
            : message.seq <= boundary;
        if (isInherited) inherited += 1;
        return !isInherited;
      });
    }
    sessions.push({
      row,
      messages,
      inheritedMessages: inherited,
      boundarySeq: boundary,
      isSubagent: Boolean(row.parentID) && !row.forkSessionID,
    });
  }

  void sessionByID;
  return { sessions, schema };
}

export function emptyTokens(): TokenUsage {
  return {
    input: EMPTY_TOKENS.input,
    output: EMPTY_TOKENS.output,
    reasoning: EMPTY_TOKENS.reasoning,
    cache: { ...EMPTY_TOKENS.cache },
  };
}
