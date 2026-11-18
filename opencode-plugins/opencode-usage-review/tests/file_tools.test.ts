import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  clearReadCache,
  outlineFile,
  renderOutline,
  renderSmartRead,
  smartReadFile,
} from "../plugin/file_tools.ts";

async function tempDir(): Promise<string> {
  return mkdtemp(join(tmpdir(), "opencode-usage-review-files-"));
}

beforeEach(() => {
  clearReadCache();
});

test("outline returns Go declarations from the fallback parser", async () => {
  const root = await tempDir();
  const path = join(root, "sample.go");
  await writeFile(
    path,
    `package sample

type Config struct {
\tName string
}

func New() *Config {
\treturn &Config{}
}

func (config *Config) Handler() {}
`,
  );
  const result = await outlineFile({ root, path, goplsPath: false });
  assert.equal(result.language, "go");
  assert.ok(result.symbols.some((symbol) => symbol.name === "Config" && symbol.kind === "type"));
  assert.ok(result.symbols.some((symbol) => symbol.name === "New" && symbol.kind === "func"));
  assert.ok(result.symbols.some((symbol) => symbol.name === "Handler" && symbol.kind === "method"));
  assert.match(renderOutline(result), /symbols:/);
});

test("outline returns Markdown headings with line numbers", async () => {
  const root = await tempDir();
  const path = join(root, "guide.md");
  await writeFile(path, "# Title\n\n## Section\n\n### Detail\n");
  const result = await outlineFile({ root, path });
  assert.equal(result.language, "markdown");
  assert.deepEqual(
    result.symbols.map((symbol) => [symbol.name, symbol.kind, symbol.line]),
    [
      ["Title", "h1", 1],
      ["Section", "h2", 3],
      ["Detail", "h3", 5],
    ],
  );
});

test("outline returns TypeScript declarations", async () => {
  const root = await tempDir();
  const path = join(root, "sample.ts");
  await writeFile(
    path,
    `export interface Config { name: string }
export type Mode = "auto" | "content"
export class Runner {}
export function run() {}
export const value = 1
`,
  );
  const result = await outlineFile({ root, path });
  assert.equal(result.language, "typescript");
  assert.ok(result.symbols.some((symbol) => symbol.name === "Config" && symbol.kind === "interface"));
  assert.ok(result.symbols.some((symbol) => symbol.name === "Runner" && symbol.kind === "class"));
  assert.ok(result.symbols.some((symbol) => symbol.name === "run" && symbol.kind === "function"));
});

test("smart_read caches unchanged ranges and respects compaction", async () => {
  const root = await tempDir();
  const path = join(root, "small.ts");
  await writeFile(path, Array.from({ length: 20 }, (_, index) => `line ${index + 1}`).join("\n"));
  const base = { root, path, sessionID: "ses_test", offset: 1, limit: 5 };
  const first = await smartReadFile({ ...base, compactedSince: async () => false });
  assert.equal(first.cached, false);
  assert.match(first.content ?? "", /1: line 1/);
  assert.match(first.content ?? "", /5: line 5/);

  const cached = await smartReadFile({ ...base, compactedSince: async () => false });
  assert.equal(cached.cached, true);
  assert.equal(cached.content, undefined);
  assert.match(cached.note ?? "", /Unchanged/);

  const forced = await smartReadFile({ ...base, compactedSince: async () => false, force: true });
  assert.equal(forced.cached, false);
  assert.match(forced.content ?? "", /line 1/);

  const compacted = await smartReadFile({ ...base, compactedSince: async () => true });
  assert.equal(compacted.cached, false);
  assert.equal(compacted.compacted, true);
  assert.match(compacted.content ?? "", /line 1/);
});

test("smart_read reports content changes", async () => {
  const root = await tempDir();
  const path = join(root, "changing.ts");
  await writeFile(path, "const a = 1\n");
  const base = { root, path, sessionID: "ses_change", compactedSince: async () => false };
  await smartReadFile(base);
  await writeFile(path, "const a = 2\n");
  const changed = await smartReadFile(base);
  assert.equal(changed.changed, true);
  assert.match(changed.content ?? "", /const a = 2/);
});

test("smart_read returns an outline for large files in auto mode", async () => {
  const root = await tempDir();
  const path = join(root, "large.ts");
  const lines = Array.from({ length: 500 }, (_, index) =>
    index % 20 === 0 ? `export function function${index}() {}` : `const value${index} = ${index}`,
  );
  await writeFile(path, lines.join("\n"));
  const result = await smartReadFile({
    root,
    path,
    sessionID: "ses_large",
    mode: "auto",
    goplsPath: false,
  });
  assert.equal(result.mode, "outline");
  assert.ok((result.outline?.symbols.length ?? 0) > 0);
  assert.match(renderSmartRead(result), /mode: outline/);
});
