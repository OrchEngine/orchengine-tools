import type {
  AssistantMessage,
  ExplorationStats,
  LoadedSession,
  ToolCall,
} from "./types.ts";
import type { TimeRange } from "./time.ts";

function stringInput(tool: ToolCall, key: string): string {
  const value = tool.input[key];
  return typeof value === "string" ? value : "";
}

function numberInput(tool: ToolCall, key: string): number | undefined {
  const value = tool.input[key];
  return typeof value === "number" ? value : undefined;
}

function readKey(tool: ToolCall): string {
  return `${stringInput(tool, "path")}|${numberInput(tool, "offset") ?? 0}|${numberInput(tool, "limit") ?? 0}`;
}

export function computeExploration(
  sessions: LoadedSession[],
  range: TimeRange,
): ExplorationStats {
  let readCalls = 0;
  let fullFileReads = 0;
  let rangeReads = 0;
  let truncatedReads = 0;
  let readOutputBytes = 0;
  let exactRepeats = 0;
  let redundantRepeats = 0;
  let postCompactionRepeats = 0;
  let editedRepeats = 0;
  let grepCalls = 0;
  let editCalls = 0;
  const readPaths = new Set<string>();
  const editedPaths = new Set<string>();
  const grepPatterns = new Set<string>();
  const readCounts = new Map<string, number>();
  const exactRepeatCounts = new Map<string, number>();
  const grepCounts = new Map<string, number>();

  for (const session of sessions) {
    const lastRead = new Map<string, number>();
    const lastEdit = new Map<string, number>();
    let lastCompaction = 0;

    for (const message of session.messages) {
      if (message.timeCreated < range.from || message.timeCreated >= range.to) continue;
      if (message.kind === "compaction") {
        lastCompaction = message.timeCreated;
        continue;
      }
      if (message.kind !== "assistant") continue;
      const assistant = message as AssistantMessage;
      for (const tool of assistant.toolCalls) {
        if (tool.name === "read") {
          const path = stringInput(tool, "path");
          if (!path) continue;
          readCalls += 1;
          readPaths.add(path);
          readCounts.set(path, (readCounts.get(path) ?? 0) + 1);
          const offset = numberInput(tool, "offset");
          const limit = numberInput(tool, "limit");
          if (offset === undefined && limit === undefined) fullFileReads += 1;
          else rangeReads += 1;
          if (tool.truncated) truncatedReads += 1;
          readOutputBytes += Buffer.byteLength(tool.outputText, "utf8");

          const key = readKey(tool);
          const previous = lastRead.get(key);
          if (previous !== undefined) {
            exactRepeats += 1;
            exactRepeatCounts.set(path, (exactRepeatCounts.get(path) ?? 0) + 1);
            if (lastCompaction > previous) postCompactionRepeats += 1;
            else if ((lastEdit.get(path) ?? 0) > previous) editedRepeats += 1;
            else redundantRepeats += 1;
          }
          lastRead.set(key, tool.timeCreated);
          continue;
        }
        if (tool.name === "grep") {
          grepCalls += 1;
          const pattern = stringInput(tool, "pattern");
          if (pattern) {
            grepPatterns.add(pattern);
            grepCounts.set(pattern, (grepCounts.get(pattern) ?? 0) + 1);
          }
          continue;
        }
        if (tool.name === "edit" || tool.name === "write") {
          const path = stringInput(tool, "path");
          if (!path) continue;
          editCalls += 1;
          editedPaths.add(path);
          lastEdit.set(path, tool.timeCreated);
        }
      }
    }
  }

  let readThenEdited = 0;
  for (const path of readPaths) {
    if (editedPaths.has(path)) readThenEdited += 1;
  }
  const uniqueReadPaths = readPaths.size;
  const topRepeatedReads = [...readCounts.entries()]
    .filter(([, reads]) => reads > 1)
    .map(([path, reads]) => ({
      path,
      reads,
      exactRepeats: exactRepeatCounts.get(path) ?? 0,
    }))
    .sort((left, right) => right.reads - left.reads || right.exactRepeats - left.exactRepeats)
    .slice(0, 10);
  const topGrepPatterns = [...grepCounts.entries()]
    .filter(([, calls]) => calls > 1)
    .map(([pattern, calls]) => ({ pattern, calls }))
    .sort((left, right) => right.calls - left.calls)
    .slice(0, 10);
  return {
    readCalls,
    uniqueReadPaths,
    fullFileReads,
    rangeReads,
    truncatedReads,
    readOutputBytes,
    readAmplification: uniqueReadPaths > 0 ? readCalls / uniqueReadPaths : 0,
    exactRepeats,
    redundantRepeats,
    postCompactionRepeats,
    editedRepeats,
    grepCalls,
    uniqueGrepPatterns: grepPatterns.size,
    repeatedGrepPatterns: Math.max(0, grepCalls - grepPatterns.size),
    editCalls,
    uniqueEditedFiles: editedPaths.size,
    filesReadThenEdited: readThenEdited,
    filesReadNeverEdited: Math.max(0, uniqueReadPaths - readThenEdited),
    topRepeatedReads,
    topGrepPatterns,
  };
}
