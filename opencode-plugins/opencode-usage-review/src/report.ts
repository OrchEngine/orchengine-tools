import type { ActivityKey, ReportData, ReportTotals, SessionLabel, SessionMetrics } from "./types.ts";
import { formatDateTime, formatDuration, formatMoney, formatPercent } from "./time.ts";

function escapeCell(value: string): string {
  return value.replaceAll("|", "\\|").replaceAll("\n", " ");
}

function shortTitle(title: string, length = 52): string {
  const clean = title.replace(/\s+/g, " ").trim();
  if (clean.length <= length) return clean;
  return `${clean.slice(0, length - 1)}…`;
}

function shortSessionID(id: string): string {
  return id.length > 18 ? `${id.slice(0, 15)}…` : id;
}

function quotaSection(report: ReportData): string[] {
  if (report.quota.length === 0) {
    return [
      "## Quota (current)",
      "",
      "Quota unavailable. Install `@slkiser/opencode-quota` or enable its JSON export.",
      "",
    ];
  }
  const lines = ["## Quota (current)", ""];
  for (const snapshot of report.quota) {
    lines.push(`**${snapshot.provider}**`);
    for (const window of snapshot.windows) {
      const remaining = Math.max(0, Math.min(100, window.percentRemaining));
      const marker = remaining <= 20 ? " ⚠" : "";
      const reset = window.resetAt ? ` · resets ${formatDateTime(window.resetAt)}` : "";
      lines.push(`- ${window.label}: ${Math.round(remaining)}% left${reset}${marker}`);
    }
    lines.push("");
  }
  return lines;
}

function stepsPerPrompt(totals: ReportTotals): number {
  return totals.userTurns > 0 ? totals.steps / totals.userTurns : 0;
}

function toolsPerStep(totals: ReportTotals): number {
  return totals.steps > 0 ? totals.toolCalls / totals.steps : 0;
}

function reasoningShare(totals: ReportTotals): number {
  const completion = totals.tokens.output + totals.tokens.reasoning;
  return completion > 0 ? totals.tokens.reasoning / completion : 0;
}

function totalsSection(report: ReportData): string[] {
  const totals = report.totals;
  const elapsedMs = Math.max(1, Math.min(report.to, report.generatedAt) - report.from);
  const coverage = totals.activeMs / elapsedMs;
  const lines = [
    "## At a glance",
    "",
    `- **${totals.sessions}** sessions${totals.subagentSessions > 0 ? ` (+${totals.subagentSessions} subagents)` : ""} · **${totals.userTurns}** prompts · **${totals.steps}** steps · **${totals.toolCalls}** tool calls`,
    `- Active time: **${formatDuration(totals.activeMs)}** of ${formatDuration(elapsedMs)} elapsed (${formatPercent(coverage)}) · inactive (incl. breaks/nights): **${formatDuration(totals.idleMs)}**`,
    `- Failures: **${totals.failedToolCalls}** tool errors · **${totals.failedCommands}** command failures`,
    `- List-price value: **${formatMoney(totals.listCost)}** (subscription billed separately)`,
    `- ${stepsPerPrompt(totals).toFixed(1)} steps/prompt · ${toolsPerStep(totals).toFixed(1)} tool calls/step · ${formatPercent(reasoningShare(totals))} reasoning`,
    `- Tokens: ${Math.round(totals.tokens.input / 1_000_000 * 100) / 100}M input · ${Math.round((totals.tokens.output + totals.tokens.reasoning) / 1_000) / 1}K output · ${Math.round(totals.tokens.cache.read / 1_000_000 * 10) / 10}M cache read`,
  ];
  if (totals.unpricedSteps > 0) {
    lines.push(`- ⚠ ${totals.unpricedSteps} steps used models without pricing; their cost is excluded.`);
  }
  lines.push("");
  return lines;
}

function sessionFlags(session: SessionMetrics): string[] {
  const flags: string[] = [];
  if (session.redundantReads > 0) flags.push(`${session.redundantReads} redundant reads`);
  if (session.repeatedCommands > 0) flags.push(`${session.repeatedCommands} repeated commands`);
  if (session.failedCommandRetries > 0) flags.push(`${session.failedCommandRetries} failed retries`);
  if (session.failedToolCalls > 0) flags.push(`${session.failedToolCalls} failed tools`);
  if (session.failedCommands > 0) flags.push(`${session.failedCommands} failed commands`);
  if (session.compactions > 0) flags.push(`${session.compactions} compactions`);
  if (session.spanMs >= 24 * 60 * 60 * 1000) flags.push("multi-day");
  if (session.inheritedMessages > 0) flags.push(`${session.inheritedMessages} inherited`);
  if (session.unpricedSteps > 0) flags.push(`${session.unpricedSteps} unpriced`);
  return flags;
}

function sessionTable(sessions: SessionMetrics[], limit: number): string[] {
  if (sessions.length === 0) return ["_No sessions in this range._", ""];
  const lines = [
    "| Session | Active | List $ | Prompts | Steps | Flags |",
    "| --- | ---: | ---: | ---: | ---: | --- |",
  ];
  for (const session of sessions.slice(0, limit)) {
    const marker = session.isSubagent ? "↳ " : "";
    const flags = sessionFlags(session).slice(0, 3).join("; ") || "—";
    lines.push(
      `| ${marker}${escapeCell(shortTitle(session.title))} | ${formatDuration(session.activeMs)} | ${formatMoney(session.listCost)} | ${session.userTurns} | ${session.steps} | ${escapeCell(flags)} |`,
    );
  }
  lines.push("");
  return lines;
}

function topSections(report: ReportData): string[] {
  const byCost = report.sessions.filter((session) => session.listCost > 0).slice(0, 5);
  const byActive = [...report.sessions]
    .filter((session) => !session.isSubagent && session.activeMs > 0)
    .sort((left, right) => right.activeMs - left.activeMs)
    .slice(0, 5);
  return [
    "## Top sessions by list value",
    "",
    ...sessionTable(byCost, 5),
    "## Top sessions by active time",
    "",
    ...sessionTable(byActive, 5),
  ];
}

const ACTIVITY_SHORT: Record<ActivityKey, string> = {
  exploration: "Read",
  analysis: "Analyze",
  writing: "Write",
  fixing: "Fix",
  verification: "Verify",
  planning: "Plan",
  interaction: "Ask",
  other: "Other",
};

function formatSteps(value: number): string {
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(1);
}

function formatTokenCount(value: number): string {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}M`;
  if (value >= 1_000) return `${Math.round(value / 1_000)}K`;
  return String(Math.round(value));
}

function activityCost(report: ReportData, key: string): number {
  return report.activities.find((activity) => activity.key === key)?.listCost ?? 0;
}

function activitySection(report: ReportData): string[] {
  const lines = [
    "## Where the tokens went",
    "",
  ];
  const total = report.totals.listCost;
  const share = (key: string): number => {
    if (total <= 0) return 0;
    return activityCost(report, key) / total;
  };
  const understanding = share("exploration") + share("analysis");
  const repairShareSummary = share("fixing") + share("verification");
  const other = share("interaction") + share("other");
  lines.push(
    `**Understanding ${formatPercent(understanding)} · Writing ${formatPercent(share("writing"))} · Fix+verify ${formatPercent(repairShareSummary)} · Planning ${formatPercent(share("planning"))} · Other ${formatPercent(other)}**`,
    "",
    "| Activity | Steps | Tool calls | List $ | Share | Input | Cache read | Output |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const activity of report.activities) {
    lines.push(
      `| ${activity.label} | ${formatSteps(activity.steps)} | ${activity.toolCalls} | ${formatMoney(activity.listCost)} | ${formatPercent(activity.share)} | ${formatTokenCount(activity.tokens.input)} | ${formatTokenCount(activity.tokens.cache.read)} | ${formatTokenCount(activity.tokens.output + activity.tokens.reasoning)} |`,
    );
  }
  const repair = activityCost(report, "fixing") + activityCost(report, "verification");
  const repairShare = report.totals.listCost > 0 ? repair / report.totals.listCost : 0;
  lines.push(
    "",
    `**Fixing + verification**: **${formatPercent(repairShare)}** of list value.`,
    "",
    "_A step's tokens are split equally across its tool calls; a step with no tools is planning. This is an attribution, not a per-tool invoice._",
    "",
  );

  if (report.tools.length > 0) {
    lines.push(
      "### Top tools by list value",
      "",
      "| Tool | Calls | List $ | Share |",
      "| --- | ---: | ---: | ---: |",
    );
    for (const tool of report.tools.slice(0, 10)) {
      lines.push(
        `| ${escapeCell(tool.name)} | ${tool.calls} | ${formatMoney(tool.listCost)} | ${formatPercent(tool.share)} |`,
      );
    }
    lines.push("");
  }
  return lines;
}

function economicsSection(report: ReportData): string[] {
  const total = report.totals.listCost;
  const writing = activityCost(report, "writing");
  const reading = activityCost(report, "exploration") + activityCost(report, "analysis");
  const verification = activityCost(report, "verification");
  const fixing = activityCost(report, "fixing");
  const planning = activityCost(report, "planning");
  const repairShare = total > 0 ? (fixing + verification) / total : 0;
  const editingCost = report.sessions
    .filter((session) => session.hasEdit)
    .reduce((sum, session) => sum + session.listCost, 0);
  const preEditShare =
    editingCost > 0 ? report.totals.preEditCost / editingCost : 0;
  const planningPerPrompt =
    report.totals.userTurns > 0 ? planning / report.totals.userTurns : 0;
  const averagePreEditSteps =
    report.totals.sessionsWithEdit > 0
      ? report.totals.preEditSteps / report.totals.sessionsWithEdit
      : 0;
  const readPerWrite = writing > 0 ? formatMoney(reading / writing) : "n/a";
  const verifyPerWrite = writing > 0 ? formatMoney(verification / writing) : "n/a";
  const fixPerWrite = writing > 0 ? formatMoney(fixing / writing) : "n/a";
  return [
    "## Agent economics",
    "",
    `- Reading + analysis per **$1 of writing**: **${readPerWrite}**`,
    `- Verification per **$1 of writing**: **${verifyPerWrite}**`,
    `- Fixing per **$1 of writing**: **${fixPerWrite}**`,
    `- Planning per prompt: **${formatMoney(planningPerPrompt)}**`,
    `- Fixing + verification: **${formatPercent(repairShare)}** of list value`,
    `- Before the first edit: **${formatPercent(preEditShare)}** of editing sessions' list value across **${report.totals.sessionsWithEdit}** sessions (avg ${formatSteps(averagePreEditSteps)} steps)`,
    "",
    "_This separates the cost of understanding the code from the cost of changing it. A high read/write ratio is not automatically waste; it becomes waste when the same reading repeats or the session never reaches an edit._",
    "",
  ];
}

function reworkHotspots(report: ReportData): string[] {
  const rows = report.sessions
    .filter((session) => session.listCost > 0)
    .map((session) => {
      const fixing =
        session.activities.find((activity) => activity.key === "fixing")?.listCost ?? 0;
      const verification =
        session.activities.find((activity) => activity.key === "verification")?.listCost ?? 0;
      return { session, fixing, verification, total: fixing + verification };
    })
    .filter((row) => row.total > 0 || row.session.failedCommands > 0)
    .sort((left, right) => right.total - left.total)
    .slice(0, 5);
  if (rows.length === 0) return [];
  const lines = [
    "## Rework hotspots",
    "",
    "| Session | Fix $ | Verify $ | Fix+verify % | Failed commands | Command retries | Redundant reads |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const row of rows) {
    const share = row.session.listCost > 0 ? row.total / row.session.listCost : 0;
    lines.push(
      `| ${escapeCell(shortTitle(row.session.title, 46))} | ${formatMoney(row.fixing)} | ${formatMoney(row.verification)} | ${formatPercent(share)} | ${row.session.failedCommands} | ${row.session.failedCommandRetries} | ${row.session.redundantReads} |`,
    );
  }
  lines.push("");
  return lines;
}

function explorationSection(report: ReportData): string[] {
  const stats = report.exploration;
  if (stats.readCalls === 0) return [];
  const fullFileShare = stats.fullFileReads / stats.readCalls;
  const outputMb = stats.readOutputBytes / (1024 * 1024);
  const lines = [
    "## Exploration efficiency",
    "",
    `- **${stats.readCalls} reads across ${stats.uniqueReadPaths} files** (${stats.readAmplification.toFixed(1)}x amplification)`,
    `- Full-file reads: **${stats.fullFileReads} (${formatPercent(fullFileShare)})** · range reads: ${stats.rangeReads} · truncated: ${stats.truncatedReads} · ${outputMb.toFixed(1)}MB returned`,
    `- Exact range repeats: **${stats.exactRepeats}** within sessions — **${stats.redundantRepeats} redundant**, **${stats.postCompactionRepeats} after compaction**, ${stats.editedRepeats} after edits`,
    `- Grep: **${stats.grepCalls}** calls, ${stats.uniqueGrepPatterns} unique patterns (${stats.repeatedGrepPatterns} repeats)`,
    `- Files read then edited: **${stats.filesReadThenEdited}** · read but never edited: ${stats.filesReadNeverEdited}`,
    "",
    "_Redundant = same path/offset/limit with no edit and no compaction between reads. Post-compaction re-reads are legitimate, but they show where context was lost. Read-but-never-edited includes docs and tests, so it is not automatically waste._",
    "",
  ];
  if (stats.topRepeatedReads.length > 0) {
    lines.push(
      "### Most repeated reads",
      "",
      "| File | Reads | Exact repeats |",
      "| --- | ---: | ---: |",
    );
    for (const item of stats.topRepeatedReads) {
      const short = item.path.split("/").slice(-3).join("/");
      lines.push(`| \`${escapeCell(short)}\` | ${item.reads} | ${item.exactRepeats} |`);
    }
    lines.push("");
  }
  if (stats.topGrepPatterns.length > 0) {
    lines.push(
      "### Repeated searches",
      "",
      "| Pattern | Calls |",
      "| --- | ---: |",
    );
    for (const item of stats.topGrepPatterns) {
      lines.push(`| \`${escapeCell(item.pattern.slice(0, 60))}\` | ${item.calls} |`);
    }
    lines.push("");
  }
  return lines;
}

function sessionActivitySection(report: ReportData): string[] {
  const sessions = report.sessions.filter((session) => session.listCost > 0).slice(0, 5);
  if (sessions.length === 0) return [];
  const lines = [
    "## Where each top session went",
    "",
    "| Session | Read | Analyze | Write | Fix | Verify | Plan | Other |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const session of sessions) {
    const shares = new Map(session.activities.map((activity) => [activity.key, activity]));
    const share = (key: ActivityKey): number => {
      const activity = shares.get(key);
      if (!activity || session.listCost <= 0) return 0;
      return activity.listCost / session.listCost;
    };
    lines.push(
      `| ${escapeCell(shortTitle(session.title, 46))} | ${formatPercent(share("exploration"))} | ${formatPercent(share("analysis"))} | ${formatPercent(share("writing"))} | ${formatPercent(share("fixing"))} | ${formatPercent(share("verification"))} | ${formatPercent(share("planning"))} | ${formatPercent(share("interaction") + share("other"))} |`,
    );
  }
  lines.push(
    "",
    "_Read = reading/searching, Analyze = ad-hoc scripts and git inspection, Write = edits before a failure, Fix = failed tools/commands and edits after a failure, Verify = tests/lint/build, Plan = reasoning without tools._",
    "",
  );
  return lines;
}

function modelSection(report: ReportData): string[] {
  if (report.models.length === 0) return [];
  const totalCost = report.totals.listCost;
  const lines = [
    "## Model mix",
    "",
    "| Model | Steps | List $ | Share | $/step | Output |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  ];
  for (const model of report.models) {
    const share = totalCost > 0 ? model.listCost / totalCost : 0;
    const output = Math.round((model.tokens.output + model.tokens.reasoning) / 1_000);
    const perStep = model.steps > 0 ? model.listCost / model.steps : 0;
    lines.push(
      `| ${escapeCell(model.key)} | ${model.steps} | ${formatMoney(model.listCost)} | ${formatPercent(share)} | ${formatMoney(perStep)} | ${output}K |`,
    );
  }
  const unpriced = report.models.reduce((total, model) => total + model.unpricedSteps, 0);
  if (unpriced > 0) lines.push("", `⚠ ${unpriced} steps used models without pricing.`);
  lines.push("");
  return lines;
}

function leakSections(report: ReportData): string[] {
  const lines = ["## Leaks and evidence", ""];
  const rework = report.sessions.filter(
    (session) =>
      session.redundantReads > 0 ||
      session.repeatedCommands > 0 ||
      session.failedCommandRetries > 0 ||
      session.failedToolCalls > 0 ||
      session.failedCommands > 0,
  );
  if (rework.length > 0) {
    lines.push("### Rework", "");
    for (const session of rework.slice(0, 5)) {
      const details = sessionFlags(session).join("; ");
      lines.push(`- **${shortTitle(session.title, 60)}** — ${details}`);
    }
    lines.push("");
  }

  const context = report.sessions.filter(
    (session) => session.compactions > 0 || session.contextP90 >= 150_000,
  );
  if (context.length > 0) {
    lines.push("### Context pressure", "");
    for (const session of context.slice(0, 5)) {
      lines.push(
        `- **${shortTitle(session.title, 60)}** — p90 context ${Math.round(session.contextP90 / 1000)}K, max ${Math.round(session.contextMax / 1000)}K, ${session.compactions} compaction(s)`,
      );
    }
    lines.push("");
  }

  const longLived = report.sessions
    .filter((session) => !session.isSubagent && session.spanMs >= 12 * 60 * 60 * 1000)
    .sort((left, right) => right.spanMs - left.spanMs);
  if (longLived.length > 0) {
    lines.push("### Long-lived sessions", "");
    for (const session of longLived.slice(0, 5)) {
      lines.push(
        `- **${shortTitle(session.title, 60)}** — span ${formatDuration(session.spanMs)}, active ${formatDuration(session.activeMs)}, ${session.userTurns} prompts`,
      );
    }
    lines.push("");
  }

  const outputs = report.sessions
    .filter((session) => session.largestToolOutputBytes > 50_000)
    .sort((left, right) => right.largestToolOutputBytes - left.largestToolOutputBytes);
  if (outputs.length > 0) {
    lines.push("### Large tool outputs", "");
    for (const session of outputs.slice(0, 5)) {
      lines.push(
        `- **${shortTitle(session.title, 60)}** — ${Math.round(session.largestToolOutputBytes / 1024)}KB from \`${session.largestToolOutputName ?? "tool"}\``,
      );
    }
    lines.push("");
  }

  if (lines.length === 2) lines.push("_No rework, context, or output flags in this range._", "");
  return lines;
}

function labelSummary(report: ReportData): string[] {
  const entries = Object.entries(report.labels);
  const lines = ["## Outcome labels", ""];
  if (entries.length === 0) {
    lines.push(
      "No labels yet. Label the top sessions to calibrate next week:",
      "",
      "```bash",
      `opencode-usage-review labels set <session-id> useful --note "what worked"`,
      `opencode-usage-review labels set <session-id> rework --note "what caused rework"`,
      "```",
      "",
    );
    return lines;
  }
  const byOutcome = new Map<string, { count: number; cost: number }>();
  for (const [sessionID, label] of entries) {
    const session = report.sessions.find((item) => item.sessionID === sessionID);
    if (!session) continue;
    const current = byOutcome.get(label.outcome) ?? { count: 0, cost: 0 };
    current.count += 1;
    current.cost += session.listCost;
    byOutcome.set(label.outcome, current);
  }
  for (const [outcome, value] of [...byOutcome.entries()].sort()) {
    lines.push(`- **${outcome}**: ${value.count} session(s), ${formatMoney(value.cost)} list value`);
  }
  const unlabeled = report.sessions.filter(
    (session) => session.listCost > 0 && !report.labels[session.sessionID],
  ).length;
  if (unlabeled > 0) lines.push(`- **unlabeled**: ${unlabeled} session(s) with list value > 0`);
  lines.push("");
  return lines;
}

function doneSection(report: ReportData): string[] {
  if (report.done.length === 0) return [];
  const lines = ["## Done", ""];
  for (const item of report.done) {
    const session = item.sessionID ? ` · \`${item.sessionID}\`` : "";
    const tags = item.tags.length > 0 ? ` · ${item.tags.join(", ")}` : "";
    lines.push(`- [x] ${item.text} — ${formatDateTime(item.createdAt)}${session}${tags}`);
  }
  lines.push("");
  return lines;
}

function experiments(report: ReportData): string[] {
  const suggestions: string[] = [];
  const exploration = report.exploration;
  const exploreHeavy =
    exploration.readCalls > 0 &&
    (exploration.readAmplification > 2 ||
      exploration.fullFileReads / exploration.readCalls > 0.5);
  const worstRead = exploration.topRepeatedReads[0];
  if (worstRead && worstRead.reads >= 10 && worstRead.exactRepeats === 0) {
    suggestions.push(
      `Use outline/smart_read for ${shortTitle(worstRead.path.split("/").slice(-2).join("/"), 40)} instead of reading it in ${worstRead.reads} separate ranges.`,
    );
  }
  const worstGrep = exploration.topGrepPatterns[0];
  if (worstGrep && worstGrep.calls >= 5) {
    suggestions.push(
      `Replace the repeated "${worstGrep.pattern.slice(0, 30)}" grep with go_search or a symbol query.`,
    );
  }
  if (exploreHeavy) {
    suggestions.push(
      "Use symbol navigation and outline/smart_read before full-file reads: gopls MCP (go_search, go_file_context, go_package_api, go_symbol_references) in Go modules.",
    );
  }
  if (exploration.redundantRepeats > 3) {
    suggestions.push(
      "Use smart_read instead of read; when it reports unchanged, reuse the earlier content instead of re-reading the same path and range.",
    );
  }
  if (exploration.postCompactionRepeats > 5) {
    suggestions.push(
      "After compaction, write a short working-set note (files, symbols, decisions) instead of re-reading the same files. smart_read reports compacted:true when the cache is no longer valid.",
    );
  }
  const rework = report.sessions.some(
    (session) => session.redundantReads > 2 || session.failedCommandRetries > 1,
  );
  const compactions = report.totals.compactions > 0;
  const longLived = report.sessions.some(
    (session) => !session.isSubagent && session.spanMs >= 24 * 60 * 60 * 1000,
  );
  const lowWeekly = report.quota.some((snapshot) =>
    snapshot.windows.some(
      (window) => window.key.includes("week") && window.percentRemaining <= 20,
    ),
  );
  const reasoningHeavy = reasoningShare(report.totals) > 0.5;
  if (rework) {
    suggestions.push(
      "When a read or command repeats without an intervening edit, stop and re-plan instead of retrying.",
    );
  }
  if (lowWeekly) {
    suggestions.push(
      "Weekly Go allowance is low: use free models for exploration and reserve paid models for implementation.",
    );
  }
  if (reasoningHeavy) {
    suggestions.push(
      `Reasoning is ${formatPercent(reasoningShare(report.totals))} of completion tokens; try a lower reasoning variant for simple edits and exploration.`,
    );
  }
  if (compactions) {
    suggestions.push(
      "Start a fresh session after the second compaction, or write a handoff note and continue there.",
    );
  }
  if (longLived) {
    suggestions.push(
      "Close multi-day sessions at the end of each work block; leave a short handoff note for tomorrow.",
    );
  }
  if (report.totals.unpricedSteps > 0) {
    suggestions.push("Add pricing for the unpriced models so their cost is visible next time.");
  }
  if (suggestions.length < 3) {
    suggestions.push(
      "Label the top three sessions as useful/rework/abandoned; labels are the only reliable ground truth for waste.",
    );
  }
  if (suggestions.length < 3) {
    suggestions.push("Compare active time per useful session next week, not raw token count.");
  }
  if (suggestions.length < 3) {
    suggestions.push("Try one session where you ask for a plan first, then execute in a fresh context.");
  }
  return ["## Experiments for tomorrow", "", ...suggestions.slice(0, 5).map((item) => `- [ ] ${item}`), ""];
}

function appendix(report: ReportData): string[] {
  const lines = [
    "## Appendix",
    "",
    "| Session | ID | List $ | Active | Steps | Outcome |",
    "| --- | --- | ---: | ---: | ---: | --- |",
  ];
  for (const session of report.sessions) {
    const label: SessionLabel | undefined = report.labels[session.sessionID];
    const marker = session.isSubagent ? "↳ " : "";
    lines.push(
      `| ${marker}${escapeCell(shortTitle(session.title, 40))} | \`${shortSessionID(session.sessionID)}\` | ${formatMoney(session.listCost)} | ${formatDuration(session.activeMs)} | ${session.steps} | ${label?.outcome ?? "—"} |`,
    );
  }
  lines.push(
    "",
    "Open a session with `opencode -s <full-session-id>`.",
    "",
  );
  return lines;
}

export function renderMarkdown(report: ReportData): string {
  const generated = new Date(report.generatedAt);
  const lines = [
    `# AI usage review — ${report.day ?? localRangeLabel(report)} (${report.timezone})`,
    "",
    `_Generated ${generated.toLocaleString()} · list value is an estimate for comparison, not the weighted Go allowance or your invoice._`,
    "",
    ...quotaSection(report),
    ...totalsSection(report),
    ...activitySection(report),
    ...economicsSection(report),
    ...explorationSection(report),
    ...sessionActivitySection(report),
    ...reworkHotspots(report),
    ...topSections(report),
    ...modelSection(report),
    ...leakSections(report),
    ...labelSummary(report),
    ...doneSection(report),
    ...experiments(report),
    ...appendix(report),
  ];
  return lines.join("\n");
}

function localRangeLabel(report: ReportData): string {
  const from = new Date(report.from).toLocaleDateString();
  const to = new Date(report.to - 1).toLocaleDateString();
  return from === to ? from : `${from} – ${to}`;
}

export function renderJSON(report: ReportData): string {
  return `${JSON.stringify(report, null, 2)}\n`;
}

export function renderText(report: ReportData): string {
  const totals = report.totals;
  const elapsedMs = Math.max(1, Math.min(report.to, report.generatedAt) - report.from);
  const lines: string[] = [];
  lines.push(`AI usage — ${report.day ?? localRangeLabel(report)} (${report.timezone})`);
  lines.push("");
  lines.push("Quota");
  if (report.quota.length === 0) {
    lines.push("  unavailable (install @slkiser/opencode-quota)");
  } else {
    for (const snapshot of report.quota) {
      for (const window of snapshot.windows) {
        const remaining = Math.max(0, Math.min(100, window.percentRemaining));
        const marker = remaining <= 20 ? "  ⚠" : "";
        const reset = window.resetAt ? `  resets ${formatDateTime(window.resetAt)}` : "";
        lines.push(`  ${window.label}: ${Math.round(remaining)}% left${reset}${marker}`);
      }
    }
  }
  lines.push("");
  const multiDay = report.to - report.from > 26 * 60 * 60 * 1000;
  lines.push(multiDay ? "Range" : "Day");
  lines.push(
    `  ${totals.sessions} sessions${totals.subagentSessions > 0 ? ` (+${totals.subagentSessions} subagents)` : ""} · ${totals.userTurns} prompts · ${totals.steps} steps · ${totals.toolCalls} tool calls`,
  );
  lines.push(
    `  Active ${formatDuration(totals.activeMs)} of ${formatDuration(elapsedMs)} (${formatPercent(totals.activeMs / elapsedMs)}) · inactive ${formatDuration(totals.idleMs)}`,
  );
  lines.push(`  Failures: ${totals.failedToolCalls} tool errors · ${totals.failedCommands} command failures`);
  if (report.done.length > 0) lines.push(`  Done: ${report.done.length} item(s) in this range`);
  lines.push(`  List value ${formatMoney(totals.listCost)} · input ${(totals.tokens.input / 1e6).toFixed(2)}M · cache read ${(totals.tokens.cache.read / 1e6).toFixed(1)}M`);
  lines.push(
    `  ${stepsPerPrompt(totals).toFixed(1)} steps/prompt · ${toolsPerStep(totals).toFixed(1)} tool calls/step · ${formatPercent(reasoningShare(totals))} reasoning`,
  );
  if (totals.unpricedSteps > 0) lines.push(`  ⚠ ${totals.unpricedSteps} unpriced steps`);
  lines.push("");

  const activeActivities = report.activities.filter((activity) => activity.steps > 0);
  if (activeActivities.length > 0) {
    lines.push("Where tokens went");
    const total = totals.listCost;
    const share = (key: string): number => (total > 0 ? activityCost(report, key) / total : 0);
    lines.push(
      `  Understanding ${formatPercent(share("exploration") + share("analysis"))} · Writing ${formatPercent(share("writing"))} · Repair ${formatPercent(share("fixing") + share("verification"))} · Planning ${formatPercent(share("planning"))} · Other ${formatPercent(share("interaction") + share("other"))}`,
    );
    lines.push(
      `  ${activeActivities.map((activity) => `${ACTIVITY_SHORT[activity.key]} ${formatPercent(activity.share)}`).join(" · ")}`,
    );
    const repair = activityCost(report, "fixing") + activityCost(report, "verification");
    const repairShare = totals.listCost > 0 ? repair / totals.listCost : 0;
    const topTools = report.tools
      .slice(0, 3)
      .map((tool) => `${tool.name} ${formatPercent(tool.share)}`)
      .join(" · ");
    lines.push(`  Fix+verify ${formatPercent(repairShare)}${topTools ? ` · top tools: ${topTools}` : ""}`);
    const writingCost = activityCost(report, "writing");
    const readCost = activityCost(report, "exploration") + activityCost(report, "analysis");
    const verifyCost = activityCost(report, "verification");
    const editingCost = report.sessions
      .filter((session) => session.hasEdit)
      .reduce((sum, session) => sum + session.listCost, 0);
    const preEditShare = editingCost > 0 ? totals.preEditCost / editingCost : 0;
    const perWrite = writingCost > 0 ? formatMoney(readCost / writingCost) : "n/a";
    const verifyPerWrite = writingCost > 0 ? formatMoney(verifyCost / writingCost) : "n/a";
    lines.push(
      `  Read+analyze per $1 write ${perWrite} · verify per $1 write ${verifyPerWrite} · pre-edit ${formatPercent(preEditShare)}`,
    );
    const exploration = report.exploration;
    if (exploration.readCalls > 0) {
      lines.push(
        `  Reads ${exploration.readCalls}/${exploration.uniqueReadPaths} files (${exploration.readAmplification.toFixed(1)}x) · ${exploration.redundantRepeats} redundant · ${exploration.postCompactionRepeats} post-compaction · ${formatPercent(exploration.fullFileReads / exploration.readCalls)} full-file`,
      );
    }
    const hotspot = report.sessions
      .filter((session) => session.listCost > 0)
      .map((session) => {
        const fixing =
          session.activities.find((activity) => activity.key === "fixing")?.listCost ?? 0;
        const verification =
          session.activities.find((activity) => activity.key === "verification")?.listCost ?? 0;
        return { session, total: fixing + verification };
      })
      .sort((left, right) => right.total - left.total)[0];
    if (hotspot && hotspot.total > 0) {
      lines.push(
        `  Fix hotspot: ${shortTitle(hotspot.session.title, 46)} — ${formatMoney(hotspot.total)} fix+verify, ${hotspot.session.failedCommands} failed commands`,
      );
    }
    lines.push("");
  }

  const byCost = report.sessions.filter((session) => session.listCost > 0).slice(0, 3);
  if (byCost.length > 0) {
    lines.push("Top by list value");
    for (const [index, session] of byCost.entries()) {
      const marker = session.isSubagent ? "↳ " : "";
      lines.push(
        `  ${index + 1}. ${marker}${shortTitle(session.title, 44)} — ${formatDuration(session.activeMs)} · ${formatMoney(session.listCost)} · ${session.userTurns} prompts · ${session.steps} steps`,
      );
      const flags = sessionFlags(session).slice(0, 3).join("; ");
      if (flags) lines.push(`     ${flags}`);
    }
    lines.push("");
  }

  if (report.models.length > 0) {
    lines.push("Models");
    for (const model of report.models.slice(0, 4)) {
      lines.push(`  ${model.key} — ${model.steps} steps · ${formatMoney(model.listCost)}`);
    }
    lines.push("");
  }

  const leaks = report.sessions
    .filter(
      (session) =>
        session.redundantReads > 0 ||
        session.repeatedCommands > 0 ||
        session.compactions > 0 ||
        session.failedToolCalls > 0 ||
        session.failedCommands > 0,
    )
    .slice(0, 4);
  if (leaks.length > 0) {
    lines.push("Leaks");
    for (const session of leaks) {
      lines.push(`  ${shortTitle(session.title, 44)}: ${sessionFlags(session).slice(0, 3).join("; ")}`);
    }
    lines.push("");
  }

  lines.push("Experiments");
  for (const experiment of experiments(report).slice(2)) {
    if (experiment.startsWith("- [ ] ")) lines.push(`  ${experiment.slice(6)}`);
  }
  return `${lines.join("\n")}\n`;
}

export function renderLabelSummary(label: SessionLabel): string {
  const parts: string[] = [label.outcome];
  if (label.taskType) parts.push(label.taskType);
  if (label.note) parts.push(label.note);
  return parts.join(" · ");
}

export function renderPercent(value: number): string {
  return formatPercent(value);
}
