import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildReport } from "../src/metrics.ts";
import { listSnapshots, loadSnapshot, renderComparison, saveSnapshot } from "../src/history.ts";
import { addDone, listDone } from "../src/done.ts";
import type { ReportData } from "../src/types.ts";
import { assistantData, createFixtureDB, userData, type FixtureMessage, type FixtureSession } from "./fixture.ts";

function fixtureReport(): ReportData {
  const t0 = new Date(2026, 10, 8, 10, 0, 0, 0).getTime();
  const from = new Date(2026, 10, 8, 0, 0, 0, 0).getTime();
  const to = new Date(2026, 10, 9, 0, 0, 0, 0).getTime();
  const sessions: FixtureSession[] = [{ id: "ses_history", title: "History", timeCreated: t0 }];
  const messages: FixtureMessage[] = [
    { id: "m1", sessionID: "ses_history", type: "user", seq: 1, timeCreated: t0, data: userData("do work", t0) },
    {
      id: "m2",
      sessionID: "ses_history",
      type: "assistant",
      seq: 2,
      timeCreated: t0 + 1_000,
      data: assistantData({ timeCreated: t0 + 1_000, timeCompleted: t0 + 2_000 }),
    },
  ];
  const fixture = createFixtureDB(sessions, messages);
  return buildReport({
    dbPath: fixture.path,
    range: { from, to, label: "2026-11-08" },
    quota: [],
    labels: {},
  });
}

test("history snapshots round-trip and compare", async () => {
  const previousState = process.env["XDG_STATE_HOME"];
  const state = mkdtempSync(join(tmpdir(), "opencode-usage-review-history-"));
  process.env["XDG_STATE_HOME"] = state;
  try {
    const current = fixtureReport();
    current.day = "2026-11-08";
    const previous = structuredClone(current);
    previous.day = "2026-11-07";
    previous.generatedAt -= 86_400_000;
    previous.totals.listCost = current.totals.listCost * 1.1;
    previous.totals.activeMs = current.totals.activeMs * 0.8;

    const savedCurrent = await saveSnapshot(current);
    const savedPrevious = await saveSnapshot(previous);
    assert.match(savedCurrent.key, /^day-2026-11-08$/);
    assert.match(savedPrevious.key, /^day-2026-11-07$/);

    const entries = await listSnapshots();
    assert.equal(entries.length, 2);
    assert.equal(entries[0]?.key, "day-2026-11-08");

    const loaded = await loadSnapshot(savedCurrent.key);
    assert.equal(loaded.day, "2026-11-08");
    const comparison = renderComparison(current, previous);
    assert.match(comparison, /Usage comparison/);
    assert.match(comparison, /Writing share/);
    assert.match(comparison, /Read amplification/);
  } finally {
    if (previousState === undefined) delete process.env["XDG_STATE_HOME"];
    else process.env["XDG_STATE_HOME"] = previousState;
    rmSync(state, { recursive: true, force: true });
  }
});

test("done items persist and filter by range", async () => {
  const previousState = process.env["XDG_STATE_HOME"];
  const state = mkdtempSync(join(tmpdir(), "opencode-usage-review-done-"));
  process.env["XDG_STATE_HOME"] = state;
  try {
    const item = await addDone("ship the outline tool", { sessionID: "ses_done", tags: ["tooling"] });
    assert.equal(item.text, "ship the outline tool");
    const all = await listDone();
    assert.equal(all.length, 1);
    assert.equal(all[0]?.sessionID, "ses_done");
    const inRange = await listDone({ from: item.createdAt - 1, to: item.createdAt + 1 });
    assert.equal(inRange.length, 1);
    const outOfRange = await listDone({ from: item.createdAt - 10_000, to: item.createdAt - 5_000 });
    assert.equal(outOfRange.length, 0);
  } finally {
    if (previousState === undefined) delete process.env["XDG_STATE_HOME"];
    else process.env["XDG_STATE_HOME"] = previousState;
    rmSync(state, { recursive: true, force: true });
  }
});
