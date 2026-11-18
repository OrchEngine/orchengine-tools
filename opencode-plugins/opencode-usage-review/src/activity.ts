import { messageListCost } from "./pricing.ts";
import type {
  ActivityKey,
  ActivityMetrics,
  AssistantMessage,
  SessionMessage,
  TokenUsage,
  ToolCall,
  ToolExpenditure,
} from "./types.ts";
import type { TimeRange } from "./time.ts";

export const ACTIVITY_ORDER: ActivityKey[] = [
  "exploration",
  "analysis",
  "writing",
  "fixing",
  "verification",
  "planning",
  "interaction",
  "other",
];

export const ACTIVITY_LABELS: Record<ActivityKey, string> = {
  exploration: "Exploration (reading code)",
  analysis: "Analysis / ad-hoc tooling",
  writing: "Writing code",
  fixing: "Fixing / failure handling",
  verification: "Verification (tests/lint/build)",
  planning: "Planning / reasoning-only",
  interaction: "Interaction (questions)",
  other: "Other tooling",
};

interface ToolClass {
  category: ActivityKey;
  key: string;
  name: string;
}

interface FailureState {
  pendingFailureSteps: number;
  verificationFailed: boolean;
}

function zeroTokens(): TokenUsage {
  return { input: 0, output: 0, reasoning: 0, cache: { read: 0, write: 0 } };
}

function addTokens(target: TokenUsage, source: TokenUsage, fraction: number): void {
  target.input += source.input * fraction;
  target.output += source.output * fraction;
  target.reasoning += source.reasoning * fraction;
  target.cache.read += source.cache.read * fraction;
  target.cache.write += source.cache.write * fraction;
}

function newActivity(key: ActivityKey): ActivityMetrics {
  return {
    key,
    label: ACTIVITY_LABELS[key],
    steps: 0,
    toolCalls: 0,
    tokens: zeroTokens(),
    listCost: 0,
    share: 0,
  };
}

function containsAny(text: string, needles: string[]): boolean {
  return needles.some((needle) => text.includes(needle));
}

function classifyShell(command: string): ToolClass {
  const text = command.toLowerCase();
  if (
    containsAny(text, [
      "go test",
      "make test",
      "npm test",
      "npm run test",
      "pnpm test",
      "bun test",
      "yarn test",
      "pytest",
      "cargo test",
      "playwright test",
      "vitest",
      "jest",
      "node --test",
      "go run ./cmd/testaudit",
      "make check",
    ])
  ) {
    return { category: "verification", key: "shell:test", name: "shell (test)" };
  }
  if (
    containsAny(text, [
      "golangci-lint",
      "go vet",
      "staticcheck",
      "gofmt",
      "goimports",
      "eslint",
      "prettier",
      "make lint",
      "make verify",
      "make fmt",
      "make format",
      "make typecheck",
      "npm run lint",
      "pnpm lint",
      "yarn lint",
      "typecheck",
      "tsc --noemit",
      "tsc -p",
      "npx tsc",
    ])
  ) {
    return { category: "verification", key: "shell:lint", name: "shell (lint/format)" };
  }
  if (
    containsAny(text, [
      "go build",
      "make build",
      "npm run build",
      "pnpm build",
      "yarn build",
      "bun run build",
      "cargo build",
      "go generate",
    ])
  ) {
    return { category: "verification", key: "shell:build", name: "shell (build)" };
  }
  if (
    containsAny(text, [
      "git status",
      "git diff",
      "git log",
      "git show",
      "git branch",
      "git rev-parse",
      "git ls-files",
      "git remote",
      "git blame",
    ])
  ) {
    return { category: "analysis", key: "shell:git-read", name: "shell (git read)" };
  }
  if (/^\s*git\s/.test(text) || text.includes("&& git ") || text.includes("; git ")) {
    return { category: "other", key: "shell:git", name: "shell (git write)" };
  }
  if (containsAny(text, ["python"])) {
    return { category: "analysis", key: "shell:python", name: "shell (python)" };
  }
  if (containsAny(text, ["sqlite3"])) {
    return { category: "analysis", key: "shell:sqlite3", name: "shell (sqlite3)" };
  }
  if (containsAny(text, ["jq "])) {
    return { category: "analysis", key: "shell:jq", name: "shell (jq)" };
  }
  if (containsAny(text, ["curl "])) {
    return { category: "analysis", key: "shell:curl", name: "shell (curl)" };
  }
  if (containsAny(text, ["wget "])) {
    return { category: "analysis", key: "shell:wget", name: "shell (wget)" };
  }
  if (containsAny(text, ["node "])) {
    return { category: "analysis", key: "shell:node", name: "shell (node)" };
  }
  if (containsAny(text, ["rg "])) {
    return { category: "analysis", key: "shell:rg", name: "shell (rg)" };
  }
  if (containsAny(text, ["grep "])) {
    return { category: "analysis", key: "shell:grep", name: "shell (grep)" };
  }
  if (containsAny(text, ["find "])) {
    return { category: "analysis", key: "shell:find", name: "shell (find)" };
  }
  if (containsAny(text, ["ls "])) {
    return { category: "analysis", key: "shell:ls", name: "shell (ls)" };
  }
  if (containsAny(text, ["cat "])) {
    return { category: "analysis", key: "shell:cat", name: "shell (cat)" };
  }
  if (containsAny(text, ["head "])) {
    return { category: "analysis", key: "shell:head", name: "shell (head)" };
  }
  if (containsAny(text, ["tail "])) {
    return { category: "analysis", key: "shell:tail", name: "shell (tail)" };
  }
  if (containsAny(text, ["sed "])) {
    return { category: "analysis", key: "shell:sed", name: "shell (sed)" };
  }
  if (containsAny(text, ["awk "])) {
    return { category: "analysis", key: "shell:awk", name: "shell (awk)" };
  }
  if (containsAny(text, ["wc "])) {
    return { category: "analysis", key: "shell:wc", name: "shell (wc)" };
  }
  if (containsAny(text, ["diff "])) {
    return { category: "analysis", key: "shell:diff", name: "shell (diff)" };
  }
  if (
    containsAny(text, [
      "npm install",
      "npm ci",
      "pnpm install",
      "yarn install",
      "go mod tidy",
      "go get",
      "pip install",
      "cargo fetch",
      "apt install",
      "apt-get install",
    ])
  ) {
    return { category: "other", key: "shell:install", name: "shell (install/setup)" };
  }
  return { category: "other", key: "shell", name: "shell (other)" };
}

function classifyTool(tool: ToolCall, fixing: boolean): ToolClass {
  if (tool.name === "read" || tool.name === "grep" || tool.name === "glob") {
    return { category: "exploration", key: tool.name, name: tool.name };
  }
  if (tool.name === "webfetch" || tool.name === "websearch") {
    return { category: "exploration", key: tool.name, name: tool.name };
  }
  if (tool.name === "edit" || tool.name === "write") {
    return fixing
      ? { category: "fixing", key: tool.name, name: tool.name }
      : { category: "writing", key: tool.name, name: tool.name };
  }
  if (tool.name === "shell" || tool.name === "bash") {
    return classifyShell(stringInput(tool, "command"));
  }
  if (tool.name === "question") {
    return { category: "interaction", key: "question", name: "question" };
  }
  if (tool.name === "skill") {
    return { category: "other", key: "skill", name: "skill" };
  }
  if (tool.name === "task") {
    return { category: "other", key: "task", name: "task" };
  }
  if (tool.name === "execute") {
    return { category: "analysis", key: "execute", name: "execute" };
  }
  return { category: "other", key: tool.name || "other", name: tool.name || "other" };
}

function stringInput(tool: ToolCall, key: string): string {
  const value = tool.input[key];
  return typeof value === "string" ? value : "";
}

function verificationToolFailed(tool: ToolCall): boolean {
  if (tool.status === "error") return true;
  if (tool.exitCode !== undefined && tool.exitCode !== 0) return true;
  const text = tool.outputText;
  return /(^|\n)(FAIL|--- FAIL:|panic:|not ok|Error:|error TS|make: \*\*\*|exit status [1-9])/i.test(
    text,
  );
}

function toolFailed(tool: ToolCall, toolClass: ToolClass): boolean {
  if (toolClass.category === "verification") return verificationToolFailed(tool);
  return tool.status === "error" || (tool.exitCode !== undefined && tool.exitCode !== 0);
}

function updateFailureState(
  message: AssistantMessage,
  classes: ToolClass[],
  state: FailureState,
): void {
  const failedVerification = message.toolCalls.some(
    (tool, index) =>
      classes[index]?.category === "verification" && verificationToolFailed(tool),
  );
  const succeededVerification = message.toolCalls.some(
    (tool, index) =>
      classes[index]?.category === "verification" &&
      tool.status === "completed" &&
      !verificationToolFailed(tool),
  );
  if (failedVerification) state.verificationFailed = true;
  else if (succeededVerification) state.verificationFailed = false;

  const anyFailure =
    message.toolCalls.some((tool, index) => {
      const toolClass = classes[index];
      return toolClass ? toolFailed(tool, toolClass) : tool.status === "error";
    }) || message.finish === "error";
  if (anyFailure) state.pendingFailureSteps = 3;
  else if (succeededVerification) state.pendingFailureSteps = 0;
  else if (state.pendingFailureSteps > 0) state.pendingFailureSteps -= 1;
}

function addActivityShare(
  activity: ActivityMetrics,
  message: AssistantMessage,
  fraction: number,
  cost: number,
): void {
  activity.steps += fraction;
  addTokens(activity.tokens, message.tokens, fraction);
  activity.listCost += cost * fraction;
}

function addToolShare(
  tools: Map<string, ToolExpenditure>,
  toolClass: ToolClass,
  message: AssistantMessage,
  fraction: number,
  cost: number,
): void {
  const existing = tools.get(toolClass.key) ?? {
    key: toolClass.key,
    name: toolClass.name,
    category: toolClass.category,
    calls: 0,
    steps: 0,
    tokens: zeroTokens(),
    listCost: 0,
    share: 0,
  };
  existing.calls += 1;
  existing.steps += fraction;
  addTokens(existing.tokens, message.tokens, fraction);
  existing.listCost += cost * fraction;
  tools.set(toolClass.key, existing);
}

export interface ActivityBreakdown {
  activities: ActivityMetrics[];
  tools: ToolExpenditure[];
}

export function computeActivity(
  messages: SessionMessage[],
  range: TimeRange,
): ActivityBreakdown {
  const activities = new Map<ActivityKey, ActivityMetrics>(
    ACTIVITY_ORDER.map((key) => [key, newActivity(key)]),
  );
  const tools = new Map<string, ToolExpenditure>();
  const state: FailureState = { pendingFailureSteps: 0, verificationFailed: false };

  const assistants = messages.filter(
    (message): message is AssistantMessage =>
      message.kind === "assistant" &&
      message.timeCreated >= range.from &&
      message.timeCreated < range.to,
  );

  for (const message of assistants) {
    const fixing = state.pendingFailureSteps > 0 || state.verificationFailed;
    const classes = message.toolCalls.map((tool) => classifyTool(tool, fixing));
    const cost = messageListCost(message) ?? 0;

    if (classes.length === 0) {
      const activity = activities.get("planning");
      if (activity) {
        addActivityShare(activity, message, 1, cost);
      }
    } else {
      const fraction = 1 / classes.length;
      for (let index = 0; index < classes.length; index += 1) {
        const tool = message.toolCalls[index];
        const baseClass = classes[index];
        if (!tool || !baseClass) continue;
        const category = toolFailed(tool, baseClass) ? "fixing" : baseClass.category;
        const toolClass = { ...baseClass, category };
        const activity = activities.get(category);
        if (activity) {
          activity.toolCalls += 1;
          addActivityShare(activity, message, fraction, cost);
        }
        addToolShare(tools, toolClass, message, fraction, cost);
      }
    }

    updateFailureState(message, classes, state);
  }

  return finalizeActivity(activities, tools);
}

function finalizeActivity(
  activities: Map<ActivityKey, ActivityMetrics>,
  tools: Map<string, ToolExpenditure>,
): ActivityBreakdown {
  const activityList = ACTIVITY_ORDER.map((key) => activities.get(key) ?? newActivity(key));
  const activityCost = activityList.reduce((total, activity) => total + activity.listCost, 0);
  for (const activity of activityList) {
    activity.share = activityCost > 0 ? activity.listCost / activityCost : 0;
  }
  const toolList = [...tools.values()];
  const toolCost = toolList.reduce((total, tool) => total + tool.listCost, 0);
  for (const tool of toolList) {
    tool.share = toolCost > 0 ? tool.listCost / toolCost : 0;
  }
  toolList.sort((left, right) => right.listCost - left.listCost || right.calls - left.calls);
  return { activities: activityList, tools: toolList };
}

export function mergeActivities(lists: ActivityMetrics[][]): ActivityMetrics[] {
  const merged = new Map<ActivityKey, ActivityMetrics>(
    ACTIVITY_ORDER.map((key) => [key, newActivity(key)]),
  );
  for (const list of lists) {
    for (const activity of list) {
      const target = merged.get(activity.key);
      if (!target) continue;
      target.steps += activity.steps;
      target.toolCalls += activity.toolCalls;
      addTokens(target.tokens, activity.tokens, 1);
      target.listCost += activity.listCost;
    }
  }
  return finalizeActivity(merged, new Map()).activities;
}

export function mergeTools(lists: ToolExpenditure[][]): ToolExpenditure[] {
  const merged = new Map<string, ToolExpenditure>();
  for (const list of lists) {
    for (const tool of list) {
      const target = merged.get(tool.key) ?? {
        key: tool.key,
        name: tool.name,
        category: tool.category,
        calls: 0,
        steps: 0,
        tokens: zeroTokens(),
        listCost: 0,
        share: 0,
      };
      target.calls += tool.calls;
      target.steps += tool.steps;
      addTokens(target.tokens, tool.tokens, 1);
      target.listCost += tool.listCost;
      merged.set(tool.key, target);
    }
  }
  return finalizeActivity(new Map(), merged).tools;
}
