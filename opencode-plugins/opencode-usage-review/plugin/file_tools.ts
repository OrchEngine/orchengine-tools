import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { basename, isAbsolute, relative, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface OutlineSymbol {
  name: string;
  kind: string;
  line: number;
  depth: number;
}

export interface OutlineResult {
  path: string;
  relativePath: string;
  hash: string;
  lines: number;
  language: string;
  symbols: OutlineSymbol[];
  truncated: boolean;
  note?: string;
}

export interface SmartReadResult {
  path: string;
  relativePath: string;
  hash: string;
  lines: number;
  language: string;
  mode: "content" | "outline";
  content?: string;
  outline?: OutlineResult;
  offset?: number;
  limit?: number;
  truncated?: boolean;
  cached: boolean;
  changed: boolean;
  compacted: boolean;
  note?: string;
}

export interface OutlineOptions {
  root: string;
  path: string;
  goplsPath?: string | false;
}

export interface SmartReadOptions extends OutlineOptions {
  sessionID: string;
  offset?: number;
  limit?: number;
  mode?: "auto" | "content" | "outline";
  force?: boolean;
  compactedSince?: (lastReadAt: number) => Promise<boolean>;
}

interface CacheEntry {
  hash: string;
  lastReadAt: number;
}

const readCache = new Map<string, CacheEntry>();
const AUTO_OUTLINE_LINES = 400;
const DEFAULT_CONTENT_LINES = 200;
const MAX_CONTENT_LINES = 600;
const MAX_SYMBOLS = 300;

export function clearReadCache(): void {
  readCache.clear();
}

function languageFor(path: string): string {
  const lower = path.toLowerCase();
  if (lower.endsWith(".go")) return "go";
  if (lower.endsWith(".ts") || lower.endsWith(".tsx")) return "typescript";
  if (lower.endsWith(".js") || lower.endsWith(".mjs") || lower.endsWith(".cjs")) return "javascript";
  if (lower.endsWith(".md") || lower.endsWith(".mdx")) return "markdown";
  if (lower.endsWith(".py")) return "python";
  if (lower.endsWith(".rs")) return "rust";
  if (lower.endsWith(".yaml") || lower.endsWith(".yml")) return "yaml";
  if (lower.endsWith(".json") || lower.endsWith(".jsonc")) return "json";
  if (lower.endsWith(".sh") || lower.endsWith(".bash")) return "shell";
  return "text";
}

function resolvePath(root: string, path: string): string {
  return isAbsolute(path) ? resolve(path) : resolve(root, path);
}

function displayPath(root: string, path: string): string {
  const rel = relative(root, path);
  if (rel && !rel.startsWith("..")) return rel;
  return basename(path);
}

async function readText(path: string): Promise<{ text: string; hash: string }> {
  const buffer = await readFile(path);
  if (buffer.subarray(0, 8192).includes(0)) {
    throw new Error("binary file; use a shell command if you need its bytes");
  }
  return {
    text: buffer.toString("utf8"),
    hash: createHash("sha256").update(buffer).digest("hex").slice(0, 16),
  };
}

function lineCount(text: string): number {
  if (text.length === 0) return 0;
  return text.split("\n").length;
}

function parseGoplsSymbols(output: string): OutlineSymbol[] {
  const symbols: OutlineSymbol[] = [];
  for (const line of output.split("\n")) {
    const match = /^(\s*)(.+?)\s+([A-Z][A-Za-z]+)\s+(\d+):(\d+)-/.exec(line);
    if (!match) continue;
    const depth = Math.floor((match[1]?.length ?? 0) / 2);
    symbols.push({
      name: match[2] ?? "",
      kind: match[3] ?? "symbol",
      line: Number(match[4]),
      depth,
    });
    if (symbols.length >= MAX_SYMBOLS) break;
  }
  return symbols;
}

async function goplsSymbols(
  path: string,
  root: string,
  goplsPath: string | false | undefined,
): Promise<OutlineSymbol[] | undefined> {
  if (goplsPath === false) return undefined;
  try {
    const { stdout } = await execFileAsync(goplsPath ?? "gopls", ["symbols", path], {
      cwd: root,
      timeout: 15_000,
      maxBuffer: 5 * 1024 * 1024,
    });
    const symbols = parseGoplsSymbols(stdout);
    return symbols.length > 0 ? symbols : undefined;
  } catch {
    return undefined;
  }
}

function fallbackGoSymbols(text: string): OutlineSymbol[] {
  const symbols: OutlineSymbol[] = [];
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    const method = /^func\s+\([^)]*\)\s+([A-Za-z_]\w*)/.exec(line);
    if (method) {
      symbols.push({ name: method[1] ?? "", kind: "method", line: index + 1, depth: 0 });
      continue;
    }
    const declaration = /^(func|type|var|const)\s+([A-Za-z_]\w*)/.exec(line);
    if (declaration) {
      symbols.push({ name: declaration[2] ?? "", kind: declaration[1] ?? "symbol", line: index + 1, depth: 0 });
    }
  }
  return symbols.slice(0, MAX_SYMBOLS);
}

function regexSymbols(text: string, language: string): OutlineSymbol[] {
  const symbols: OutlineSymbol[] = [];
  const lines = text.split("\n");
  const patterns: Array<{ regex: RegExp; kind: string }> =
    language === "python"
      ? [
          { regex: /^\s*(class)\s+([A-Za-z_]\w*)/, kind: "class" },
          { regex: /^\s*(def)\s+([A-Za-z_]\w*)/, kind: "function" },
        ]
      : language === "rust"
        ? [
            { regex: /^\s*(?:pub\s+)?(fn|struct|enum|trait|impl)\s+([A-Za-z_]\w*)/, kind: "symbol" },
          ]
        : [
            { regex: /^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/, kind: "function" },
            { regex: /^\s*(?:export\s+)?(?:default\s+)?class\s+([A-Za-z_$][\w$]*)/, kind: "class" },
            { regex: /^\s*(?:export\s+)?interface\s+([A-Za-z_$][\w$]*)/, kind: "interface" },
            { regex: /^\s*(?:export\s+)?type\s+([A-Za-z_$][\w$]*)/, kind: "type" },
            { regex: /^\s*(?:export\s+)?enum\s+([A-Za-z_$][\w$]*)/, kind: "enum" },
            { regex: /^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/, kind: "variable" },
          ];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    const indent = /^\s*/.exec(line)?.[0].length ?? 0;
    for (const pattern of patterns) {
      const match = pattern.regex.exec(line);
      if (!match) continue;
      if (pattern.kind === "variable" && indent > 0) break;
      const name = match[2] ?? match[1] ?? "";
      if (name) {
        symbols.push({
          name,
          kind: pattern.kind,
          line: index + 1,
          depth: Math.floor(indent / 2),
        });
      }
      break;
    }
  }
  return symbols.slice(0, MAX_SYMBOLS);
}

function markdownSymbols(text: string): OutlineSymbol[] {
  const symbols: OutlineSymbol[] = [];
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^(#{1,6})\s+(.+)$/.exec(lines[index] ?? "");
    if (!match) continue;
    symbols.push({
      name: match[2] ?? "",
      kind: `h${match[1]?.length ?? 1}`,
      line: index + 1,
      depth: (match[1]?.length ?? 1) - 1,
    });
  }
  return symbols.slice(0, MAX_SYMBOLS);
}

function yamlSymbols(text: string): OutlineSymbol[] {
  const symbols: OutlineSymbol[] = [];
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const match = /^([A-Za-z0-9_.-]+):/.exec(lines[index] ?? "");
    if (match) symbols.push({ name: match[1] ?? "", kind: "key", line: index + 1, depth: 0 });
  }
  return symbols.slice(0, MAX_SYMBOLS);
}

export async function outlineFile(options: OutlineOptions): Promise<OutlineResult> {
  const path = resolvePath(options.root, options.path);
  const { text, hash } = await readText(path);
  const language = languageFor(path);
  let symbols: OutlineSymbol[] = [];
  if (language === "go") {
    symbols = (await goplsSymbols(path, options.root, options.goplsPath)) ?? fallbackGoSymbols(text);
  } else if (language === "markdown") {
    symbols = markdownSymbols(text);
  } else if (language === "yaml") {
    symbols = yamlSymbols(text);
  } else if (language === "typescript" || language === "javascript" || language === "python" || language === "rust") {
    symbols = regexSymbols(text, language);
  }
  return {
    path,
    relativePath: displayPath(options.root, path),
    hash,
    lines: lineCount(text),
    language,
    symbols,
    truncated: symbols.length >= MAX_SYMBOLS,
    ...(symbols.length === 0 ? { note: "No symbols found. Use smart_read with mode:'content'." } : {}),
  };
}

function sliceContent(
  text: string,
  offset: number,
  limit: number,
): { content: string; truncated: boolean } {
  const lines = text.split("\n");
  const start = Math.max(0, offset - 1);
  const end = Math.min(lines.length, start + limit);
  const content = lines
    .slice(start, end)
    .map((line, index) => `${start + index + 1}: ${line}`)
    .join("\n");
  return { content, truncated: end < lines.length };
}

export async function smartReadFile(options: SmartReadOptions): Promise<SmartReadResult> {
  const path = resolvePath(options.root, options.path);
  const { text, hash } = await readText(path);
  const lines = lineCount(text);
  const language = languageFor(path);
  const mode = options.mode ?? "auto";
  const noRange = options.offset === undefined && options.limit === undefined;
  if (mode === "outline" || (mode === "auto" && noRange && lines > AUTO_OUTLINE_LINES)) {
    return {
      path,
      relativePath: displayPath(options.root, path),
      hash,
      lines,
      language,
      mode: "outline",
      outline: await outlineFile(options),
      cached: false,
      changed: false,
      compacted: false,
      ...(mode === "auto" ? { note: "Large file: outline returned. Use smart_read with offset/limit or mode:'content' for details." } : {}),
    };
  }

  const offset = Math.max(1, options.offset ?? 1);
  const limit = Math.min(MAX_CONTENT_LINES, Math.max(1, options.limit ?? DEFAULT_CONTENT_LINES));
  const cacheKey = `${options.sessionID}|${path}|${offset}|${limit}`;
  const previous = readCache.get(cacheKey);
  let compacted = false;
  if (previous && previous.hash === hash && !options.force) {
    compacted = options.compactedSince ? await options.compactedSince(previous.lastReadAt) : false;
    if (!compacted) {
      return {
        path,
        relativePath: displayPath(options.root, path),
        hash,
        lines,
        language,
        mode: "content",
        offset,
        limit,
        cached: true,
        changed: false,
        compacted: false,
        note: "Unchanged since the last read in this session. Reuse the earlier content, or call with force:true to receive it again.",
      };
    }
  }

  const { content, truncated } = sliceContent(text, offset, limit);
  readCache.set(cacheKey, { hash, lastReadAt: Date.now() });
  return {
    path,
    relativePath: displayPath(options.root, path),
    hash,
    lines,
    language,
    mode: "content",
    content,
    offset,
    limit,
    truncated,
    cached: false,
    changed: previous !== undefined && previous.hash !== hash,
    compacted,
    ...(truncated ? { note: "Use offset/limit to read the remaining lines." } : {}),
  };
}

export function renderOutline(result: OutlineResult): string {
  const lines = [
    `path: ${result.relativePath}`,
    `hash: ${result.hash}`,
    `lines: ${result.lines}`,
    `language: ${result.language}`,
    "symbols:",
  ];
  for (const symbol of result.symbols) {
    lines.push(`${"  ".repeat(symbol.depth)}${symbol.line}: ${symbol.kind} ${symbol.name}`);
  }
  if (result.symbols.length === 0) lines.push("  (none)");
  if (result.truncated) lines.push("  (truncated)");
  if (result.note) lines.push(`note: ${result.note}`);
  return `${lines.join("\n")}\n`;
}

export function renderSmartRead(result: SmartReadResult): string {
  const lines = [
    `path: ${result.relativePath}`,
    `hash: ${result.hash}`,
    `lines: ${result.lines}`,
    `language: ${result.language}`,
    `mode: ${result.mode}`,
    ...(result.offset !== undefined ? [`range: ${result.offset}-${(result.offset ?? 1) + (result.limit ?? 0) - 1}`] : []),
    `cached: ${result.cached}`,
    `changed: ${result.changed}`,
    `compacted: ${result.compacted}`,
  ];
  if (result.truncated) lines.push("truncated: true");
  if (result.note) lines.push(`note: ${result.note}`);
  if (result.mode === "outline" && result.outline) {
    lines.push("", renderOutline(result.outline));
  } else if (result.content !== undefined) {
    lines.push("", result.content);
  }
  return `${lines.join("\n")}\n`;
}
