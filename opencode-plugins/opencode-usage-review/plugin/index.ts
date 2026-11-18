import { Plugin } from "@opencode/plugin";
import {
  outlineFile,
  renderOutline,
  renderSmartRead,
  smartReadFile,
} from "./file_tools.ts";

async function sessionCompactedSince(
  context: {
    session: {
      context(input: { sessionID: string }): Promise<readonly { type: string; time?: { created?: number } }[]>;
    };
  },
  sessionID: string,
  lastReadAt: number,
): Promise<boolean> {
  try {
    const messages = await context.session.context({ sessionID });
    return messages.some(
      (message) =>
        message.type === "compaction" &&
        (message.time?.created ?? 0) > lastReadAt,
    );
  } catch {
    // If compaction state is unavailable, prefer returning content over a false cache hit.
    return true;
  }
}

export default Plugin.define({
  id: "opencode-usage-review.server",
  async setup(ctx) {
    await ctx.tool.transform((editor) => {
      editor.add({
        name: "outline",
        description:
          "Return a compact symbol outline for a file instead of its full content. Use this before reading large Go, TypeScript, JavaScript, Python, Markdown, or YAML files. Go files use gopls symbols when available. The result includes a content hash and line numbers.",
        input: {
          type: "object",
          properties: {
            path: { type: "string", description: "File path, absolute or relative to the workspace." },
          },
          required: ["path"],
          additionalProperties: false,
        },
        options: { codemode: true },
        execute: async (input, toolContext) => {
          const result = await outlineFile({
            root: ctx.location.directory,
            path: String((input as { path?: unknown }).path ?? ""),
            goplsPath: process.env["GOPLS_BIN"] ?? "gopls",
          });
          await toolContext.progress({ status: `outlined ${result.relativePath}` });
          return { content: renderOutline(result) };
        },
      });

      editor.add({
        name: "smart_read",
        description:
          "Read a file without repeating unchanged content. For files over 400 lines it returns an outline unless a range or mode:'content' is supplied. On a repeated read of the same path and range in the same session it returns 'unchanged' unless the file changed or the session was compacted; pass force:true to read again. Prefer this over the built-in read for large or repeatedly-read files.",
        input: {
          type: "object",
          properties: {
            path: { type: "string", description: "File path, absolute or relative to the workspace." },
            offset: { type: "number", description: "1-based first line. Defaults to 1." },
            limit: { type: "number", description: "Maximum lines to return. Defaults to 200; capped at 600." },
            mode: {
              type: "string",
              enum: ["auto", "content", "outline"],
              description: "auto returns an outline for large files; content always returns lines; outline always returns symbols.",
            },
            force: { type: "boolean", description: "Bypass the unchanged-read cache." },
          },
          required: ["path"],
          additionalProperties: false,
        },
        options: { codemode: true },
        execute: async (input, toolContext) => {
          const request = input as {
            path?: unknown;
            offset?: unknown;
            limit?: unknown;
            mode?: unknown;
            force?: unknown;
          };
          const mode =
            request.mode === "content" || request.mode === "outline" || request.mode === "auto"
              ? request.mode
              : "auto";
          const result = await smartReadFile({
            root: ctx.location.directory,
            path: String(request.path ?? ""),
            sessionID: toolContext.sessionID,
            ...(typeof request.offset === "number" ? { offset: request.offset } : {}),
            ...(typeof request.limit === "number" ? { limit: request.limit } : {}),
            mode,
            ...(request.force === true ? { force: true } : {}),
            goplsPath: process.env["GOPLS_BIN"] ?? "gopls",
            compactedSince: (lastReadAt) =>
              sessionCompactedSince(ctx, toolContext.sessionID, lastReadAt),
          });
          await toolContext.progress({
            status: result.cached
              ? `unchanged ${result.relativePath}`
              : `read ${result.relativePath}`,
          });
          return { content: renderSmartRead(result) };
        },
      });
    });
  },
});
