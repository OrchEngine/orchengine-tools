import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildReport } from "../src/metrics.ts";
import { messageListCost } from "../src/pricing.ts";
import { renderMarkdown } from "../src/report.ts";
import { localDayRange } from "../src/time.ts";
import { loadLabels, setLabel, isLabelOutcome, removeLabel } from "../src/labels.ts";
import type { AssistantMessage, ReportData } from "../src/types.ts";
import {
  assistantData,
  createFixtureDB,
  tokens,
  toolPart,
  userData,
  type FixtureMessage,
  type FixtureSession,
} from "./fixture.ts";

function explicitRange(year: number, month: number, day: number) {
  const from = new Date(year, month - 1, day, 0, 0, 0, 0).getTime();
  const to = new Date(year, month - 1, day + 1, 0, 0, 0, 0).getTime();
  return { from, to, label: `${year}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}` };
}

function assistantMessage(options: {
  model: string;
  providerID?: string;
  timeCreated: number;
  usage: ReturnType<typeof tokens>;
}): AssistantMessage {
  return {
    kind: "assistant",
    id: `msg_${options.timeCreated}`,
    sessionID: "ses_test",
    seq: 1,
    timeCreated: options.timeCreated,
    timeCompleted: options.timeCreated + 1_000,
    agent: "build",
    model: { id: options.model, providerID: options.providerID ?? "opencode-go" },
    tokens: options.usage,
    cost: 0,
    finish: "tool-calls",
    toolCalls: [],
    textChars: 0,
    reasoningChars: 0,
  };
}

test("fork inherited messages are excluded from steps and tokens", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [
    { id: "ses_parent", title: "Parent", timeCreated: t0 },
    {
      id: "ses_fork",
      title: "Fork",
      timeCreated: t0 + 60_000,
      forkSessionID: "ses_parent",
      forkBoundary: { type: "before", messageID: "msg_f6" },
    },
  ];
  const messages: FixtureMessage[] = [
    { id: "msg_p1", sessionID: "ses_parent", type: "user", seq: 1, timeCreated: t0, data: userData("start", t0) },
    {
      id: "msg_p2",
      sessionID: "ses_parent",
      type: "assistant",
      seq: 2,
      timeCreated: t0 + 1_000,
      data: assistantData({ timeCreated: t0 + 1_000, timeCompleted: t0 + 10_000, usage: tokens(100, 10, 0, 1_000) }),
    },
    { id: "msg_p3", sessionID: "ses_parent", type: "user", seq: 3, timeCreated: t0 + 20_000, data: userData("continue", t0 + 20_000) },
    { id: "msg_p4", sessionID: "ses_parent", type: "user", seq: 4, timeCreated: t0 + 30_000, data: userData("boundary", t0 + 30_000) },
    {
      id: "msg_p5",
      sessionID: "ses_parent",
      type: "assistant",
      seq: 5,
      timeCreated: t0 + 31_000,
      data: assistantData({ timeCreated: t0 + 31_000, timeCompleted: t0 + 40_000, usage: tokens(200, 20, 0, 2_000) }),
    },
    { id: "msg_f1", sessionID: "ses_fork", type: "user", seq: 1, timeCreated: t0, data: userData("start", t0) },
    {
      id: "msg_f2",
      sessionID: "ses_fork",
      type: "assistant",
      seq: 2,
      timeCreated: t0 + 1_000,
      data: assistantData({ timeCreated: t0 + 1_000, timeCompleted: t0 + 10_000, usage: tokens(100, 10, 0, 1_000) }),
    },
    { id: "msg_f3", sessionID: "ses_fork", type: "user", seq: 3, timeCreated: t0 + 20_000, data: userData("continue", t0 + 20_000) },
    { id: "msg_f4", sessionID: "ses_fork", type: "user", seq: 4, timeCreated: t0 + 30_000, data: userData("boundary", t0 + 30_000) },
    {
      id: "msg_f5",
      sessionID: "ses_fork",
      type: "assistant",
      seq: 5,
      timeCreated: t0 + 31_000,
      data: assistantData({ timeCreated: t0 + 31_000, timeCompleted: t0 + 40_000, usage: tokens(200, 20, 0, 2_000) }),
    },
    { id: "msg_f6", sessionID: "ses_fork", type: "user", seq: 6, timeCreated: t0 + 50_000, data: userData("fork question", t0 + 50_000) },
    {
      id: "msg_f7",
      sessionID: "ses_fork",
      type: "assistant",
      seq: 7,
      timeCreated: t0 + 51_000,
      data: assistantData({ timeCreated: t0 + 51_000, timeCompleted: t0 + 60_000, usage: tokens(300, 30, 0, 3_000) }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  const parent = report.sessions.find((session) => session.sessionID === "ses_parent");
  const fork = report.sessions.find((session) => session.sessionID === "ses_fork");
  assert.equal(parent?.steps, 2);
  assert.equal(fork?.steps, 1);
  assert.equal(fork?.inheritedMessages, 5);
  assert.equal(report.totals.steps, 3);
  assert.equal(report.totals.tokens.input, 600);
});

test("overlapping sessions contribute active time once", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [
    { id: "ses_a", title: "A", timeCreated: t0 },
    { id: "ses_b", title: "B", timeCreated: t0 + 5 * 60_000 },
  ];
  const messages: FixtureMessage[] = [
    {
      id: "msg_a1",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({ timeCreated: t0, timeCompleted: t0 + 10 * 60_000 }),
    },
    {
      id: "msg_b1",
      sessionID: "ses_b",
      type: "assistant",
      seq: 1,
      timeCreated: t0 + 5 * 60_000,
      data: assistantData({ timeCreated: t0 + 5 * 60_000, timeCompleted: t0 + 15 * 60_000 }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  assert.equal(report.totals.activeMs, 15 * 60_000);
});

test("a gap longer than ten minutes is not counted as active", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_a", title: "A", timeCreated: t0 }];
  const messages: FixtureMessage[] = [
    {
      id: "msg_a1",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({ timeCreated: t0, timeCompleted: t0 + 2 * 60_000 }),
    },
    {
      id: "msg_a2",
      sessionID: "ses_a",
      type: "assistant",
      seq: 2,
      timeCreated: t0 + 22 * 60_000,
      data: assistantData({ timeCreated: t0 + 22 * 60_000, timeCompleted: t0 + 24 * 60_000 }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  assert.equal(report.totals.activeMs, 4 * 60_000);
});

test("redundant reads are counted only when the file did not change", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [
    { id: "ses_dup", title: "Duplicate read", timeCreated: t0 },
    { id: "ses_edit", title: "Read after edit", timeCreated: t0 },
    { id: "ses_write", title: "Read after write", timeCreated: t0 },
  ];
  const messages: FixtureMessage[] = [
    {
      id: "msg_dup",
      sessionID: "ses_dup",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({
        timeCreated: t0,
        timeCompleted: t0 + 1_000,
        content: [
          toolPart({ id: "t1", name: "read", input: { path: "/tmp/a.go" }, timeCreated: t0 }),
          toolPart({ id: "t2", name: "read", input: { path: "/tmp/a.go" }, timeCreated: t0 + 500 }),
        ],
      }),
    },
    {
      id: "msg_edit",
      sessionID: "ses_edit",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({
        timeCreated: t0,
        timeCompleted: t0 + 1_000,
        content: [
          toolPart({ id: "t3", name: "read", input: { path: "/tmp/b.go" }, timeCreated: t0 }),
          toolPart({ id: "t4", name: "edit", input: { path: "/tmp/b.go" }, timeCreated: t0 + 500 }),
          toolPart({ id: "t5", name: "read", input: { path: "/tmp/b.go" }, timeCreated: t0 + 900 }),
        ],
      }),
    },
    {
      id: "msg_write",
      sessionID: "ses_write",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({
        timeCreated: t0,
        timeCompleted: t0 + 1_000,
        content: [
          toolPart({ id: "t6", name: "read", input: { path: "/tmp/c.go" }, timeCreated: t0 }),
          toolPart({ id: "t7", name: "write", input: { path: "/tmp/c.go" }, timeCreated: t0 + 500 }),
          toolPart({ id: "t8", name: "read", input: { path: "/tmp/c.go" }, timeCreated: t0 + 900 }),
        ],
      }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  const duplicate = report.sessions.find((session) => session.sessionID === "ses_dup");
  const edited = report.sessions.find((session) => session.sessionID === "ses_edit");
  const written = report.sessions.find((session) => session.sessionID === "ses_write");
  assert.equal(duplicate?.redundantReads, 1);
  assert.equal(edited?.redundantReads, 0);
  assert.equal(written?.redundantReads, 0);
});

test("DeepSeek peak pricing is twice off-peak", () => {
  const peak = Date.UTC(2026, 10, 10, 2, 0, 0);
  const offPeak = Date.UTC(2026, 10, 10, 12, 0, 0);
  const usage = tokens(0, 1_000_000, 0, 0);
  const peakCost = messageListCost(
    assistantMessage({ model: "deepseek-v4.1-flash", timeCreated: peak, usage }),
  );
  const offPeakCost = messageListCost(
    assistantMessage({ model: "deepseek-v4.1-flash", timeCreated: offPeak, usage }),
  );
  assert.equal(peakCost, 1.2);
  assert.equal(offPeakCost, 0.6);
});

test("unknown models are reported as unpriced", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_a", title: "A", timeCreated: t0 }];
  const messages: FixtureMessage[] = [
    {
      id: "msg_a1",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({ timeCreated: t0, model: "mystery-model" }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  assert.equal(report.totals.unpricedSteps, 1);
  assert.equal(report.totals.listCost, 0);
});

test("local day range excludes the next local day", () => {
  const late = new Date(2026, 10, 8, 23, 59, 0, 0);
  const nextDay = new Date(2026, 10, 9, 0, 1, 0, 0);
  const range = localDayRange("2026-11-08", new Date(2026, 10, 9, 12, 0, 0, 0));
  const sessions: FixtureSession[] = [{ id: "ses_a", title: "A", timeCreated: late.getTime() }];
  const messages: FixtureMessage[] = [
    {
      id: "msg_late",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: late.getTime(),
      data: assistantData({ timeCreated: late.getTime() }),
    },
    {
      id: "msg_next",
      sessionID: "ses_a",
      type: "assistant",
      seq: 2,
      timeCreated: nextDay.getTime(),
      data: assistantData({ timeCreated: nextDay.getTime() }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  assert.equal(report.totals.steps, 1);
});

test("labels round-trip through the state directory", async () => {
  const previous = process.env["XDG_STATE_HOME"];
  process.env["XDG_STATE_HOME"] = mkdtempSync(join(tmpdir(), "opencode-usage-review-state-"));
  try {
    assert.equal(isLabelOutcome("useful"), true);
    assert.equal(isLabelOutcome("nonsense"), false);
    await setLabel("ses_test", "rework", "repeated reads", "debug");
    const labels = await loadLabels();
    assert.equal(labels["ses_test"]?.outcome, "rework");
    assert.equal(labels["ses_test"]?.note, "repeated reads");
    assert.equal(labels["ses_test"]?.taskType, "debug");
    assert.equal(await removeLabel("ses_test"), true);
    assert.equal(await removeLabel("ses_test"), false);
    assert.deepEqual(await loadLabels(), {});
  } finally {
    if (previous === undefined) delete process.env["XDG_STATE_HOME"];
    else process.env["XDG_STATE_HOME"] = previous;
  }
});

test("model mix ranks models by list value", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_a", title: "A", timeCreated: t0 }];
  const messages: FixtureMessage[] = [
    {
      id: "msg_deepseek",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({
        timeCreated: t0,
        model: "deepseek-v4.1-flash",
        usage: tokens(0, 1_000_000, 0, 0),
      }),
    },
    {
      id: "msg_claude",
      sessionID: "ses_a",
      type: "assistant",
      seq: 2,
      timeCreated: t0 + 1_000,
      data: assistantData({
        timeCreated: t0 + 1_000,
        model: "claude-haiku-5-5",
        usage: tokens(0, 6_000_000, 0, 0),
      }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  assert.equal(report.models.length, 2);
  assert.equal(report.models[0]?.modelID, "claude-haiku-5-5");
  assert.equal(report.models[0]?.listCost, 3);
  assert.equal(report.models[1]?.modelID, "deepseek-v4.1-flash");
});

test("activity breakdown separates reading, writing, fixing, and verification", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_activity", title: "Activity", timeCreated: t0 }];
  const step = (offset: number, content: Record<string, unknown>[], input: number) => ({
    id: `msg_${offset}`,
    sessionID: "ses_activity",
    type: "assistant" as const,
    seq: offset + 1,
    timeCreated: t0 + offset * 1_000,
    data: assistantData({
      timeCreated: t0 + offset * 1_000,
      timeCompleted: t0 + offset * 1_000 + 500,
      usage: tokens(input, 10, 0, 1_000),
      content,
    }),
  });
  const messages: FixtureMessage[] = [
    step(0, [], 100),
    step(1, [toolPart({ id: "r1", name: "read", input: { path: "/tmp/a.go" }, timeCreated: t0 + 1_000 })], 200),
    step(2, [toolPart({ id: "e1", name: "edit", input: { path: "/tmp/a.go" }, timeCreated: t0 + 2_000 })], 300),
    step(
      3,
      [
        toolPart({
          id: "t1",
          name: "shell",
          input: { command: "go test ./..." },
          exitCode: 1,
          output: "--- FAIL: TestA",
          timeCreated: t0 + 3_000,
        }),
      ],
      400,
    ),
    step(4, [toolPart({ id: "e2", name: "edit", input: { path: "/tmp/a.go" }, timeCreated: t0 + 4_000 })], 500),
    step(
      5,
      [
        toolPart({
          id: "t2",
          name: "shell",
          input: { command: "go test ./..." },
          exitCode: 0,
          output: "ok",
          timeCreated: t0 + 5_000,
        }),
      ],
      600,
    ),
    step(6, [toolPart({ id: "e3", name: "edit", input: { path: "/tmp/a.go" }, timeCreated: t0 + 6_000 })], 700),
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  const session = report.sessions[0];
  assert.ok(session);
  const activity = (key: string) => session.activities.find((item) => item.key === key);
  assert.equal(activity("planning")?.steps, 1);
  assert.equal(activity("exploration")?.steps, 1);
  assert.equal(activity("writing")?.steps, 2);
  assert.equal(activity("fixing")?.steps, 2);
  assert.equal(activity("verification")?.steps, 1);
  assert.equal(session.failedCommands, 1);
  assert.equal(report.totals.failedCommands, 1);
  assert.equal(session.preEditSteps, 2);
  assert.ok(session.preEditCost > 0);
  assert.equal(report.tools.find((tool) => tool.key === "shell:test")?.calls, 2);
  assert.equal(report.tools.find((tool) => tool.key === "read")?.calls, 1);
  assert.equal(report.tools.find((tool) => tool.key === "edit")?.calls, 3);
  const inputTotal = session.activities.reduce((sum, item) => sum + item.tokens.input, 0);
  assert.ok(Math.abs(inputTotal - session.tokens.input) < 1e-6);
  const costTotal = session.activities.reduce((sum, item) => sum + item.listCost, 0);
  assert.ok(Math.abs(costTotal - session.listCost) < 1e-6);
});

test("exploration stats separate redundant, edited, and post-compaction reads", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_explore", title: "Explore", timeCreated: t0 }];
  const assistant = (seq: number, offset: number, content: Record<string, unknown>[]) => ({
    id: `msg_${seq}`,
    sessionID: "ses_explore",
    type: "assistant" as const,
    seq,
    timeCreated: t0 + offset * 1_000,
    data: assistantData({
      timeCreated: t0 + offset * 1_000,
      timeCompleted: t0 + offset * 1_000 + 500,
      usage: tokens(100, 10, 0, 1000),
      content,
    }),
  });
  const readA = (id: string, offset: number) =>
    toolPart({
      id,
      name: "read",
      input: { path: "/tmp/a.go", offset: 0, limit: 100 },
      timeCreated: t0 + offset * 1_000,
    });
  const messages: FixtureMessage[] = [
    assistant(1, 1, [readA("r1", 1)]),
    assistant(2, 2, [toolPart({ id: "e1", name: "edit", input: { path: "/tmp/a.go" }, timeCreated: t0 + 2_000 })]),
    assistant(3, 3, [readA("r2", 3)]),
    { id: "c1", sessionID: "ses_explore", type: "compaction", seq: 4, timeCreated: t0 + 4_000, data: { time: { created: t0 + 4_000 } } },
    assistant(5, 5, [readA("r3", 5)]),
    assistant(6, 6, [readA("r4", 6)]),
    assistant(7, 7, [toolPart({ id: "g1", name: "grep", input: { pattern: "Needle" }, timeCreated: t0 + 7_000 })]),
    assistant(8, 8, [toolPart({ id: "g2", name: "grep", input: { pattern: "Needle" }, timeCreated: t0 + 8_000 })]),
    assistant(9, 9, [toolPart({ id: "r5", name: "read", input: { path: "/tmp/b.go" }, timeCreated: t0 + 9_000 })]),
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report = buildReport({ dbPath: fixture.path, range, quota: [], labels: {} });
  const stats = report.exploration;
  assert.equal(stats.readCalls, 5);
  assert.equal(stats.uniqueReadPaths, 2);
  assert.equal(stats.fullFileReads, 1);
  assert.equal(stats.rangeReads, 4);
  assert.equal(stats.readAmplification, 2.5);
  assert.equal(stats.exactRepeats, 3);
  assert.equal(stats.editedRepeats, 1);
  assert.equal(stats.postCompactionRepeats, 1);
  assert.equal(stats.redundantRepeats, 1);
  assert.equal(stats.grepCalls, 2);
  assert.equal(stats.uniqueGrepPatterns, 1);
  assert.equal(stats.repeatedGrepPatterns, 1);
  assert.equal(stats.editCalls, 1);
  assert.equal(stats.filesReadThenEdited, 1);
  assert.equal(stats.filesReadNeverEdited, 1);
});

test("markdown report includes quota warnings and top sessions", () => {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const range = explicitRange(2026, 11, 8);
  const sessions: FixtureSession[] = [{ id: "ses_a", title: "Important session", timeCreated: t0 }];
  const messages: FixtureMessage[] = [
    {
      id: "msg_a1",
      sessionID: "ses_a",
      type: "assistant",
      seq: 1,
      timeCreated: t0,
      data: assistantData({ timeCreated: t0, timeCompleted: t0 + 60_000 }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  const report: ReportData = buildReport({
    dbPath: fixture.path,
    range,
    labels: {},
    quota: [
      {
        provider: "opencode-go",
        windows: [
          { key: "opencode-go.weekly", label: "OpenCode Go Weekly", percentRemaining: 14 },
        ],
      },
    ],
  });
  const markdown = renderMarkdown(report);
  assert.match(markdown, /## Quota/);
  assert.match(markdown, /## Where the tokens went/);
  assert.match(markdown, /## Agent economics/);
  assert.match(markdown, /14% left ⚠/);
  assert.match(markdown, /Important session/);
  assert.match(markdown, /## Experiments for tomorrow/);
});
