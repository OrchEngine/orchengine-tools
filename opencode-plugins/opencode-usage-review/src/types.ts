export interface TokenUsage {
  input: number;
  output: number;
  reasoning: number;
  cache: {
    read: number;
    write: number;
  };
}

export interface ModelRef {
  id: string;
  providerID: string;
  variant?: string;
}

export interface ToolCall {
  id: string;
  name: string;
  status: string;
  input: Record<string, unknown>;
  outputText: string;
  exitCode?: number;
  truncated?: boolean;
  timeCreated: number;
  timeRan?: number;
  timeCompleted?: number;
}

export interface AssistantMessage {
  kind: "assistant";
  id: string;
  sessionID: string;
  seq: number;
  timeCreated: number;
  timeCompleted?: number;
  agent: string;
  model: ModelRef;
  tokens: TokenUsage;
  cost: number;
  finish?: string;
  toolCalls: ToolCall[];
  textChars: number;
  reasoningChars: number;
}

export interface UserMessage {
  kind: "user";
  id: string;
  sessionID: string;
  seq: number;
  timeCreated: number;
  text: string;
}

export interface CompactionMessage {
  kind: "compaction";
  id: string;
  sessionID: string;
  seq: number;
  timeCreated: number;
}

export interface OtherMessage {
  kind: "other";
  id: string;
  sessionID: string;
  seq: number;
  timeCreated: number;
  type: string;
}

export type SessionMessage =
  | AssistantMessage
  | UserMessage
  | CompactionMessage
  | OtherMessage;

export interface ForkBoundary {
  type: "before" | "through";
  messageID: string;
}

export interface SessionRow {
  id: string;
  title: string;
  directory: string;
  parentID?: string;
  forkSessionID?: string;
  forkBoundary?: ForkBoundary;
  agent?: string;
  model?: ModelRef;
  idleOutcome?: string;
  timeCreated: number;
  timeUpdated: number;
}

export interface LoadedSession {
  row: SessionRow;
  messages: SessionMessage[];
  inheritedMessages: number;
  boundarySeq?: number;
  isSubagent: boolean;
}

export interface QuotaWindow {
  key: string;
  label: string;
  percentRemaining: number;
  resetAt?: number;
}

export interface QuotaSnapshot {
  provider: string;
  fetchedAt?: number;
  windows: QuotaWindow[];
}

export interface SessionMetrics {
  sessionID: string;
  title: string;
  directory: string;
  isSubagent: boolean;
  agent?: string;
  models: string[];
  activeMs: number;
  idleMs: number;
  spanMs: number;
  userTurns: number;
  steps: number;
  toolCalls: number;
  failedToolCalls: number;
  failedCommands: number;
  compactions: number;
  tokens: TokenUsage;
  listCost: number;
  unpricedSteps: number;
  contextP50: number;
  contextP90: number;
  contextMax: number;
  reasoningShare: number;
  redundantReads: number;
  repeatedCommands: number;
  failedCommandRetries: number;
  editedFiles: number;
  mostEditedFile?: string;
  mostEditedFileCount: number;
  largestToolOutputBytes: number;
  largestToolOutputName?: string;
  inheritedMessages: number;
  lastActivity?: number;
  outcome?: string;
  activities: ActivityMetrics[];
  tools: ToolExpenditure[];
  preEditCost: number;
  preEditSteps: number;
  hasEdit: boolean;
}

export interface ReportTotals {
  sessions: number;
  subagentSessions: number;
  userTurns: number;
  steps: number;
  toolCalls: number;
  failedToolCalls: number;
  failedCommands: number;
  compactions: number;
  activeMs: number;
  idleMs: number;
  tokens: TokenUsage;
  listCost: number;
  unpricedSteps: number;
  preEditCost: number;
  preEditSteps: number;
  sessionsWithEdit: number;
}

export interface ExplorationStats {
  readCalls: number;
  uniqueReadPaths: number;
  fullFileReads: number;
  rangeReads: number;
  truncatedReads: number;
  readOutputBytes: number;
  readAmplification: number;
  exactRepeats: number;
  redundantRepeats: number;
  postCompactionRepeats: number;
  editedRepeats: number;
  grepCalls: number;
  uniqueGrepPatterns: number;
  repeatedGrepPatterns: number;
  editCalls: number;
  uniqueEditedFiles: number;
  filesReadThenEdited: number;
  filesReadNeverEdited: number;
  topRepeatedReads: Array<{ path: string; reads: number; exactRepeats: number }>;
  topGrepPatterns: Array<{ pattern: string; calls: number }>;
}

export type ActivityKey =
  | "exploration"
  | "analysis"
  | "writing"
  | "fixing"
  | "verification"
  | "planning"
  | "interaction"
  | "other";

export interface ActivityMetrics {
  key: ActivityKey;
  label: string;
  steps: number;
  toolCalls: number;
  tokens: TokenUsage;
  listCost: number;
  share: number;
}

export interface ToolExpenditure {
  key: string;
  name: string;
  category: ActivityKey;
  calls: number;
  steps: number;
  tokens: TokenUsage;
  listCost: number;
  share: number;
}

export interface ReportData {
  from: number;
  to: number;
  day?: string;
  timezone: string;
  generatedAt: number;
  quota: QuotaSnapshot[];
  totals: ReportTotals;
  sessions: SessionMetrics[];
  models: ModelMetrics[];
  activities: ActivityMetrics[];
  tools: ToolExpenditure[];
  exploration: ExplorationStats;
  labels: Record<string, SessionLabel>;
  done: DoneItem[];
}

export interface SessionLabel {
  outcome: "useful" | "rework" | "abandoned" | "explore";
  note?: string;
  taskType?: string;
  updatedAt: number;
}

export interface DoneItem {
  id: string;
  createdAt: number;
  text: string;
  sessionID?: string;
  tags: string[];
}

export interface ModelMetrics {
  key: string;
  providerID: string;
  modelID: string;
  variant?: string;
  steps: number;
  tokens: TokenUsage;
  listCost: number;
  unpricedSteps: number;
}
