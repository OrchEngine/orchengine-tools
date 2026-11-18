import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Plugin } from "@opencode/plugin/tui";

const execFileAsync = promisify(execFile);
const bunRuntime = (globalThis as { Bun?: { which(command: string): string | null } }).Bun;
const nodeBinary = bunRuntime?.which("node") ?? "node";

function shortSessionTitle(id: string): string {
  return id.length > 18 ? `${id.slice(0, 15)}…` : id;
}

async function runReview(args: string[]): Promise<string> {
  const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
  const { stdout } = await execFileAsync(nodeBinary, [cli, "report", ...args, "--no-save"], {
    timeout: 120_000,
    maxBuffer: 20 * 1024 * 1024,
  });
  return stdout;
}

interface ReviewSession {
  sessionID: string;
  title: string;
  listCost: number;
  activeMs: number;
  steps: number;
}

interface ReviewPayload {
  sessions: ReviewSession[];
  labels: Record<string, unknown>;
}

async function loadReviewSessions(): Promise<ReviewSession[]> {
  const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
  const { stdout } = await execFileAsync(nodeBinary, [cli, "report", "--day", "today", "--json", "--no-quota", "--no-save"], {
    timeout: 120_000,
    maxBuffer: 20 * 1024 * 1024,
  });
  const payload = JSON.parse(stdout) as ReviewPayload;
  return payload.sessions
    .filter((session) => session.listCost > 0 && !payload.labels[session.sessionID])
    .sort((left, right) => right.listCost - left.listCost)
    .slice(0, 5);
}

async function saveReviewLabel(sessionID: string, outcome: string, note?: string): Promise<void> {
  const cli = fileURLToPath(new URL("../src/cli.ts", import.meta.url));
  const args = [cli, "labels", "set", sessionID, outcome];
  if (note) args.push("--note", note);
  await execFileAsync(nodeBinary, args, { timeout: 30_000, maxBuffer: 1_000_000 });
}

export default Plugin.define({
  id: "opencode-usage-review.tui",
  async setup(context) {
    context.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "opencode-usage-review.today",
          title: "AI usage review: today",
          group: "AI usage",
          palette: true,
          slash: { name: "usage-review", aliases: ["usage"] },
          run: async () => {
            const report = await runReview(["--day", "today", "--text"]);
            await context.ui.dialog.alert({
              title: "AI usage review — today",
              message: report,
            });
          },
        },
        {
          id: "opencode-usage-review.week",
          title: "AI usage review: last 7 days",
          group: "AI usage",
          palette: true,
          slash: { name: "usage-week" },
          run: async () => {
            const report = await runReview(["--days", "7", "--text"]);
            await context.ui.dialog.alert({
              title: "AI usage review — last 7 days",
              message: report,
            });
          },
        },
        {
          id: "opencode-usage-review.label",
          title: "AI usage review: label a session",
          group: "AI usage",
          palette: true,
          slash: { name: "usage-label" },
          run: async () => {
            const sessions = await loadReviewSessions();
            if (sessions.length === 0) {
              context.ui.toast.show({
                title: "AI usage review",
                message: "No unlabeled sessions with a list value today.",
              });
              return;
            }
            const sessionID = await context.ui.dialog.select({
              title: "Label a session",
              options: sessions.map((session) => ({
                title: `${session.title.slice(0, 56)} · $${session.listCost.toFixed(2)}`,
                value: session.sessionID,
              })),
            });
            if (!sessionID) return;
            const outcome = await context.ui.dialog.select({
              title: "Outcome",
              options: [
                { title: "Useful — achieved the intended result", value: "useful" },
                { title: "Rework — needed repeated attempts", value: "rework" },
                { title: "Abandoned — no result", value: "abandoned" },
                { title: "Explore — open-ended investigation", value: "explore" },
              ],
            });
            if (!outcome) return;
            const note = await context.ui.dialog.prompt({
              title: "Note (optional)",
              placeholder: "What caused the outcome?",
            });
            await saveReviewLabel(sessionID, outcome, note || undefined);
            context.ui.toast.show({
              title: "Session labeled",
              message: `${outcome} · ${shortSessionTitle(sessionID)}`,
            });
          },
        },
      ],
      bindings: ["opencode-usage-review.today", "opencode-usage-review.week"],
    }));
  },
});
