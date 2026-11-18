import { loadDatabase, openReadOnly, resolveDBPath, type LoadedDatabase } from "./db.ts";
import { computeActivity, mergeActivities, mergeTools } from "./activity.ts";
import { computeExploration } from "./exploration.ts";
import { messageListCost } from "./pricing.ts";
import type {
  AssistantMessage,
  LoadedSession,
  ModelMetrics,
  QuotaSnapshot,
  ReportData,
  ReportTotals,
  SessionLabel,
  SessionMetrics,
  TokenUsage,
  ToolCall,
} from "./types.ts";
import type { TimeRange } from "./time.ts";

const ACTIVE_GAP_MS = 10 * 60 * 1000;

function sumTokens(target: TokenUsage, message: AssistantMessage): void {
  target.input += message.tokens.input;
  target.output += message.tokens.output;
  target.reasoning += message.tokens.reasoning;
  target.cache.read += message.tokens.cache.read;
  target.cache.write += message.tokens.cache.write;
}

function zeroTokens(): TokenUsage {
  return { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } };
}

function percentile(values: number[], ratio: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil(sorted.length * ratio) - 1));
  return sorted[index] ?? 0;
}

function stringInput(tool: ToolCall, key: string): string {
  const value = tool.input[key];
  return typeof value === "string" ? value : "";
}

function numberInput(tool: ToolCall, key: string): number | undefined {
  const value = tool.input[key];
  return typeof value === "number" ? value : undefined;
}

interface Interval {
  start: number;
  end: number;
}

function mergeIntervals(intervals: Interval[]): Interval[] {
  if (intervals.length === 0) return [];
  const sorted = [...intervals].sort((left, right) => left.start - right.start);
  const merged: Interval[] = [];
  for (const interval of sorted) {
    const last = merged[merged.length - 1];
    if (!last || interval.start > last.end + ACTIVE_GAP_MS) {
      merged.push({ ...interval });
      continue;
    }
    last.end = Math.max(last.end, interval.end);
  }
  return merged;
}

function activityTiming(messages: LoadedSession["messages"]): {
  activeMs: number;
  idleMs: number;
  spanMs: number;
} {
  const intervals: Interval[] = [];
  for (const message of messages) {
    if (message.kind === "assistant") {
      const end = Math.max(message.timeCreated, message.timeCompleted ?? message.timeCreated);
      intervals.push({ start: message.timeCreated, end });
    } else if (message.kind === "user" || message.kind === "compaction") {
      intervals.push({ start: message.timeCreated, end: message.timeCreated });
    }
  }
  if (intervals.length === 0) return { activeMs: 0, idleMs: 0, spanMs: 0 };
  const merged = mergeIntervals(intervals);
  let activeMs = 0;
  let idleMs = 0;
  for (const interval of merged) {
    activeMs += Math.max(0, interval.end - interval.start);
  }
  for (let index = 1; index < merged.length; index += 1) {
    const previous = merged[index - 1];
    const current = merged[index];
    if (!previous || !current) continue;
    idleMs += Math.max(0, current.start - previous.end);
  }
  const first = merged[0];
  const last = merged[merged.length - 1];
  return {
    activeMs,
    idleMs,
    spanMs: first && last ? Math.max(0, last.end - first.start) : 0,
  };
}

function toolTimeline(messages: LoadedSession["messages"]): ToolCall[] {
  const tools: ToolCall[] = [];
  for (const message of messages) {
    if (message.kind === "assistant") tools.push(...message.toolCalls);
  }
  return tools.sort((left, right) => left.timeCreated - right.timeCreated);
}

function countRework(tools: ToolCall[]): {
  redundantReads: number;
  repeatedCommands: number;
  failedCommandRetries: number;
  editedFiles: number;
  mostEditedFile?: string;
  mostEditedFileCount: number;
} {
  const lastReadByKey = new Map<string, ToolCall>();
  const lastEditByPath = new Map<string, number>();
  let redundantReads = 0;
  const commandCounts = new Map<string, { total: number; failures: number; retries: number }>();
  const editCounts = new Map<string, number>();

  for (const tool of tools) {
    if (tool.name === "read" || tool.name === "write" || tool.name === "edit") {
      const path = stringInput(tool, "path");
      if (path && (tool.name === "edit" || tool.name === "write")) {
        lastEditByPath.set(path, tool.timeCreated);
        if (tool.name === "edit") {
          editCounts.set(path, (editCounts.get(path) ?? 0) + 1);
        }
      }
      if (tool.name === "read" && path) {
        const key = `${path}|${numberInput(tool, "offset") ?? 0}|${numberInput(tool, "limit") ?? 0}`;
        const previous = lastReadByKey.get(key);
        if (previous) {
          const lastEdit = lastEditByPath.get(path);
          if (lastEdit === undefined || lastEdit <= previous.timeCreated) {
            redundantReads += 1;
          }
        }
        lastReadByKey.set(key, tool);
      }
      continue;
    }

    if (tool.name === "shell" || tool.name === "bash") {
      const command = stringInput(tool, "command").trim().replace(/\s+/g, " ");
      if (!command) continue;
      const entry = commandCounts.get(command) ?? { total: 0, failures: 0, retries: 0 };
      if (entry.failures > 0) entry.retries += 1;
      entry.total += 1;
      if (tool.status === "error" || (tool.exitCode !== undefined && tool.exitCode !== 0)) {
        entry.failures += 1;
      }
      commandCounts.set(command, entry);
    }
  }

  let repeatedCommands = 0;
  let failedCommandRetries = 0;
  for (const entry of commandCounts.values()) {
    if (entry.total > 1) repeatedCommands += entry.total - 1;
    failedCommandRetries += entry.retries;
  }

  let mostEditedFile: string | undefined;
  let mostEditedFileCount = 0;
  for (const [path, count] of editCounts) {
    if (count > mostEditedFileCount) {
      mostEditedFile = path;
      mostEditedFileCount = count;
    }
  }

  return {
    redundantReads,
    repeatedCommands,
    failedCommandRetries,
    editedFiles: editCounts.size,
    mostEditedFile,
    mostEditedFileCount,
  };
}

function largestOutput(tools: ToolCall[]): { bytes: number; name?: string } {
  let bytes = 0;
  let name: string | undefined;
  for (const tool of tools) {
    const length = tool.outputText.length;
    if (length > bytes) {
      bytes = length;
      name = tool.name;
    }
  }
  return name ? { bytes, name } : { bytes };
}

export function computeSessionMetrics(
  session: LoadedSession,
  range: TimeRange,
): SessionMetrics | undefined {
  const messages = session.messages.filter(
    (message) => message.timeCreated >= range.from && message.timeCreated < range.to,
  );
  if (messages.length === 0) return undefined;

  const assistants = messages.filter(
    (message): message is AssistantMessage => message.kind === "assistant",
  );
  const tools = toolTimeline(messages);
  const tokens = zeroTokens();
  let listCost = 0;
  let unpricedSteps = 0;
  const contexts: number[] = [];
  for (const message of assistants) {
    sumTokens(tokens, message);
    const cost = messageListCost(message);
    if (cost === undefined) unpricedSteps += 1;
    else listCost += cost;
    contexts.push(message.tokens.input + message.tokens.cache.read);
  }

  const timing = activityTiming(messages);
  const rework = countRework(tools);
  const output = largestOutput(tools);
  const activity = computeActivity(messages, range);
  const firstEditIndex = assistants.findIndex((message) =>
    message.toolCalls.some((tool) => tool.name === "edit" || tool.name === "write"),
  );
  const preEditMessages = firstEditIndex > 0 ? assistants.slice(0, firstEditIndex) : [];
  const preEditCost = preEditMessages.reduce(
    (total, message) => total + (messageListCost(message) ?? 0),
    0,
  );
  const reasoningTotal = tokens.reasoning;
  const completionTotal = tokens.output + tokens.reasoning;
  const models = [...new Set(assistants.map((message) => message.model.id))].sort();
  const last = messages.reduce((latest, message) => Math.max(latest, message.timeCreated), 0);

  return {
    sessionID: session.row.id,
    title: session.row.title || "(untitled session)",
    directory: session.row.directory,
    isSubagent: session.isSubagent,
    agent: session.row.agent,
    models,
    activeMs: session.isSubagent ? 0 : timing.activeMs,
    idleMs: session.isSubagent ? 0 : timing.idleMs,
    spanMs: timing.spanMs,
    userTurns: messages.filter((message) => message.kind === "user").length,
    steps: assistants.length,
    toolCalls: tools.length,
    failedToolCalls:
      tools.filter((tool) => tool.status === "error").length +
      assistants.filter((message) => message.finish === "error").length,
    failedCommands: tools.filter(
      (tool) =>
        (tool.name === "shell" || tool.name === "bash") &&
        (tool.status === "error" || (tool.exitCode !== undefined && tool.exitCode !== 0)),
    ).length,
    compactions: messages.filter((message) => message.kind === "compaction").length,
    tokens,
    listCost,
    unpricedSteps,
    contextP50: percentile(contexts, 0.5),
    contextP90: percentile(contexts, 0.9),
    contextMax: contexts.reduce((max, value) => Math.max(max, value), 0),
    reasoningShare: completionTotal > 0 ? reasoningTotal / completionTotal : 0,
    redundantReads: rework.redundantReads,
    repeatedCommands: rework.repeatedCommands,
    failedCommandRetries: rework.failedCommandRetries,
    editedFiles: rework.editedFiles,
    mostEditedFile: rework.mostEditedFile,
    mostEditedFileCount: rework.mostEditedFileCount,
    largestToolOutputBytes: output.bytes,
    largestToolOutputName: output.name,
    inheritedMessages: session.inheritedMessages,
    lastActivity: last > 0 ? last : undefined,
    outcome: session.row.idleOutcome,
    activities: activity.activities,
    tools: activity.tools,
    preEditCost,
    preEditSteps: preEditMessages.length,
    hasEdit: firstEditIndex >= 0,
  };
}

function aggregateTotals(
  sessions: SessionMetrics[],
  globalTiming: { activeMs: number; idleMs: number },
): ReportTotals {
  const tokens = zeroTokens();
  let userTurns = 0;
  let steps = 0;
  let toolCalls = 0;
  let failedToolCalls = 0;
  let failedCommands = 0;
  let compactions = 0;
  let listCost = 0;
  let unpricedSteps = 0;
  let preEditCost = 0;
  let preEditSteps = 0;
  let sessionsWithEdit = 0;
  let topLevelSessions = 0;
  let subagentSessions = 0;
  for (const session of sessions) {
    if (session.isSubagent) subagentSessions += 1;
    else topLevelSessions += 1;
    userTurns += session.userTurns;
    steps += session.steps;
    toolCalls += session.toolCalls;
    failedToolCalls += session.failedToolCalls;
    failedCommands += session.failedCommands;
    compactions += session.compactions;
    listCost += session.listCost;
    unpricedSteps += session.unpricedSteps;
    if (session.hasEdit) {
      sessionsWithEdit += 1;
      preEditCost += session.preEditCost;
      preEditSteps += session.preEditSteps;
    }
    tokens.input += session.tokens.input;
    tokens.output += session.tokens.output;
    tokens.reasoning += session.tokens.reasoning;
    tokens.cache.read += session.tokens.cache.read;
    tokens.cache.write += session.tokens.cache.write;
  }
  return {
    sessions: topLevelSessions,
    subagentSessions,
    userTurns,
    steps,
    toolCalls,
    failedToolCalls,
    failedCommands,
    compactions,
    activeMs: globalTiming.activeMs,
    idleMs: globalTiming.idleMs,
    tokens,
    listCost,
    unpricedSteps,
    preEditCost,
    preEditSteps,
    sessionsWithEdit,
  };
}

export interface BuildReportOptions {
  dbPath?: string;
  range: TimeRange;
  quota: QuotaSnapshot[];
  labels: Record<string, SessionLabel>;
}

function combinedTopLevelTiming(
  sessions: LoadedSession[],
  range: TimeRange,
): { activeMs: number; idleMs: number; spanMs: number } {
  const messages: LoadedSession["messages"] = [];
  for (const session of sessions) {
    if (session.isSubagent) continue;
    for (const message of session.messages) {
      if (message.timeCreated >= range.from && message.timeCreated < range.to) {
        messages.push(message);
      }
    }
  }
  return activityTiming(messages);
}

function computeModelMetrics(sessions: LoadedSession[], range: TimeRange): ModelMetrics[] {
  const byModel = new Map<string, ModelMetrics>();
  for (const session of sessions) {
    for (const message of session.messages) {
      if (message.kind !== "assistant") continue;
      if (message.timeCreated < range.from || message.timeCreated >= range.to) continue;
      const key = `${message.model.providerID}/${message.model.id}${message.model.variant ? `#${message.model.variant}` : ""}`;
      const entry = byModel.get(key) ?? {
        key,
        providerID: message.model.providerID,
        modelID: message.model.id,
        ...(message.model.variant ? { variant: message.model.variant } : {}),
        steps: 0,
        tokens: zeroTokens(),
        listCost: 0,
        unpricedSteps: 0,
      };
      entry.steps += 1;
      sumTokens(entry.tokens, message);
      const cost = messageListCost(message);
      if (cost === undefined) entry.unpricedSteps += 1;
      else entry.listCost += cost;
      byModel.set(key, entry);
    }
  }
  return [...byModel.values()].sort(
    (left, right) => right.listCost - left.listCost || right.steps - left.steps,
  );
}

export function buildReport(options: BuildReportOptions): ReportData {
  const db = openReadOnly(resolveDBPath(options.dbPath));
  try {
    const loaded = loadDatabase(db);
    const sessions: SessionMetrics[] = [];
    for (const session of loaded.sessions) {
      const metrics = computeSessionMetrics(session, options.range);
      if (metrics) sessions.push(metrics);
    }
    sessions.sort((left, right) => right.listCost - left.listCost);
    const globalTiming = combinedTopLevelTiming(loaded.sessions, options.range);
    return {
      from: options.range.from,
      to: options.range.to,
      day: options.range.label,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      generatedAt: Date.now(),
      quota: options.quota,
      totals: aggregateTotals(sessions, globalTiming),
      sessions,
      models: computeModelMetrics(loaded.sessions, options.range),
      activities: mergeActivities(sessions.map((session) => session.activities)),
      tools: mergeTools(sessions.map((session) => session.tools)),
      exploration: computeExploration(loaded.sessions, options.range),
      labels: options.labels,
      done: [],
    };
  } finally {
    db.close();
  }
}
