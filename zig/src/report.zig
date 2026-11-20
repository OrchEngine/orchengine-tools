const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");
const graph = @import("graph.zig");

const graph_view_js = @embedFile("graph_view.js");

const Model = model.Model;
const Gpa = model.Gpa;

pub const Paths = struct {
    html: []const u8,
    imports_dot: []const u8,
    imports_svg: []const u8,
    calls_dot: []const u8,
    calls_svg: []const u8,
    fields_dot: []const u8,
    fields_svg: []const u8,
    imports_rendered: bool,
    calls_rendered: bool,
    fields_rendered: bool,
};

pub fn write(
    model_ptr: *Model,
    io: Io,
    out_dir: []const u8,
    with_graphs: bool,
) !Paths {
    const gpa = model_ptr.gpa;
    try Io.Dir.cwd().createDirPath(io, out_dir);

    const html_path = try std.fs.path.join(gpa, &.{ out_dir, "report.html" });
    const imports_dot = try std.fs.path.join(gpa, &.{ out_dir, "imports.dot" });
    const imports_svg = try std.fs.path.join(gpa, &.{ out_dir, "imports.svg" });
    const calls_dot = try std.fs.path.join(gpa, &.{ out_dir, "calls.dot" });
    const calls_svg = try std.fs.path.join(gpa, &.{ out_dir, "calls.svg" });
    const fields_dot = try std.fs.path.join(gpa, &.{ out_dir, "fields.dot" });
    const fields_svg = try std.fs.path.join(gpa, &.{ out_dir, "fields.svg" });

    var hierarchy = try graph.build(model_ptr);
    defer hierarchy.deinit();

    try writeImportDot(model_ptr, &hierarchy, io, imports_dot);
    try writeCallDot(model_ptr, io, calls_dot);
    if (model_ptr.config.track_fields) try writeFieldDot(model_ptr, io, fields_dot);

    var layout = graph.Layout.load(gpa, io, imports_dot) catch graph.Layout.empty(gpa);
    defer layout.deinit();
    var payload = std.Io.Writer.Allocating.init(gpa);
    defer payload.deinit();
    try graph.writePayload(&payload.writer, model_ptr, &hierarchy, &layout);

    var imports_rendered = false;
    var calls_rendered = false;
    var fields_rendered = false;
    if (with_graphs) {
        imports_rendered = renderSvg(io, imports_dot, imports_svg);
        calls_rendered = renderSvg(io, calls_dot, calls_svg);
        if (model_ptr.config.track_fields) fields_rendered = renderSvgEngine(io, "sfdp", fields_dot, fields_svg);
        if (!imports_rendered) std.debug.print("zigdepends: graphviz failed for {s}\n", .{imports_dot});
        if (!calls_rendered) std.debug.print("zigdepends: graphviz failed for {s}\n", .{calls_dot});
        if (model_ptr.config.track_fields and !fields_rendered) std.debug.print("zigdepends: graphviz failed for {s}\n", .{fields_dot});
    }

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try writeHtml(model_ptr, io, w, calls_svg, fields_svg, imports_rendered, calls_rendered, fields_rendered, payload.written());
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = html_path, .data = aw.written() });

    return .{
        .html = html_path,
        .imports_dot = imports_dot,
        .imports_svg = imports_svg,
        .calls_dot = calls_dot,
        .calls_svg = calls_svg,
        .fields_dot = fields_dot,
        .fields_svg = fields_svg,
        .imports_rendered = imports_rendered,
        .calls_rendered = calls_rendered,
        .fields_rendered = fields_rendered,
    };
}

fn renderSvg(io: Io, dot_path: []const u8, svg_path: []const u8) bool {
    return renderSvgEngine(io, "dot", dot_path, svg_path);
}

fn renderSvgEngine(io: Io, engine: []const u8, dot_path: []const u8, svg_path: []const u8) bool {
    const argv = [_][]const u8{ engine, "-Tsvg", dot_path, "-o", svg_path };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

fn dotStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => {},
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn writeImportDot(model_ptr: *Model, hierarchy: *const graph.Hierarchy, io: Io, path: []const u8) !void {
    var aw = std.Io.Writer.Allocating.init(model_ptr.gpa);
    defer aw.deinit();
    try graph.writeDetailed(&aw.writer, model_ptr, hierarchy);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn writeCallDot(model_ptr: *Model, io: Io, path: []const u8) !void {
    const gpa = model_ptr.gpa;
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("digraph calls {\n");
    try w.writeAll("  graph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, nodesep=0.3, ranksep=0.7];\n");
    try w.writeAll("  node [shape=box, style=\"rounded,filled\", fontname=\"Helvetica\", fontsize=8];\n");
    try w.writeAll("  edge [fontname=\"Helvetica\", fontsize=6, arrowsize=0.6, color=\"#8c959f\"];\n");

    const nfns = model_ptr.fns.items.len;
    const selected = try gpa.alloc(bool, nfns);
    @memset(selected, false);

    // Always include cycle members and call-chain members.
    for (model_ptr.fns.items, 0..) |f, i| {
        if (f.in_call_cycle) selected[i] = true;
    }
    for (model_ptr.chains.items) |chain| {
        for (chain.nodes) |fn_idx| selected[fn_idx] = true;
    }

    // Add highest-debt functions until the cap.
    var order = try gpa.alloc(u32, nfns);
    for (0..nfns) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, model_ptr, lessDebt);
    var count: usize = 0;
    for (selected) |s| {
        if (s) count += 1;
    }
    for (order) |fn_idx| {
        if (count >= model_ptr.settings.max_call_nodes) break;
        if (selected[fn_idx]) continue;
        selected[fn_idx] = true;
        count += 1;
    }

    for (model_ptr.fns.items, 0..) |f, i| {
        if (!selected[i]) continue;
        const label = try std.fmt.allocPrint(gpa, "{s}\n{s}:{d}", .{
            f.name,
            model_ptr.fileLabel(f.file),
            f.line,
        });
        try w.print("  fn{d} [fillcolor=", .{i});
        if (f.in_call_cycle) {
            try w.writeAll("\"#fbe9e7\", color=\"#d93025\", penwidth=1.6");
        } else if (f.debt_min >= 60) {
            try w.writeAll("\"#fff3cd\", color=\"#e37400\"");
        } else {
            try w.writeAll("\"#eef2f7\", color=\"#8c959f\"");
        }
        try w.writeAll(", label=");
        try dotStr(w, label);
        try w.writeAll(", tooltip=");
        try dotStr(w, model_ptr.fileLabel(f.file));
        try w.writeAll("];\n");
    }

    for (model_ptr.calls.items) |call| {
        const caller = call.caller orelse continue;
        const callee = call.resolved orelse continue;
        if (!selected[caller] or !selected[callee]) continue;
        const caller_fn = model_ptr.fns.items[caller];
        try w.print("  fn{d} -> fn{d} [tooltip=", .{ caller, callee });
        const tip = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ model_ptr.fileLabel(caller_fn.file), call.line });
        try dotStr(w, tip);
        if (caller_fn.cycle_id != null and caller_fn.cycle_id == model_ptr.fns.items[callee].cycle_id) {
            try w.writeAll(", color=\"#d93025\", penwidth=1.6");
        }
        try w.writeAll("];\n");
    }

    try w.writeAll("}\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn writeFieldDot(model_ptr: *Model, io: Io, path: []const u8) !void {
    const gpa = model_ptr.gpa;
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("digraph fields {\n");
    try w.writeAll("  graph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, nodesep=0.35, ranksep=0.7];\n");
    try w.writeAll("  node [shape=box, style=\"rounded,filled\", fontname=\"Helvetica\", fontsize=8];\n");
    try w.writeAll("  edge [fontname=\"Helvetica\", fontsize=7, arrowsize=0.7];\n");

    const type_used = try gpa.alloc(bool, model_ptr.types.items.len);
    const fn_used = try gpa.alloc(bool, model_ptr.fns.items.len);
    @memset(type_used, false);
    @memset(fn_used, false);
    for (model_ptr.field_accesses.items) |access| {
        type_used[access.type_id] = true;
        fn_used[access.fn_idx] = true;
    }

    for (model_ptr.types.items, 0..) |t, type_idx| {
        if (!type_used[type_idx]) continue;
        var allocator_field = false;
        var io_field = false;
        for (t.fields.items) |field_id| {
            const field = model_ptr.fields.items[field_id];
            if (field.is_allocator) allocator_field = true;
            if (field.is_io) io_field = true;
        }
        try w.print("  ty{d} [fillcolor=", .{type_idx});
        if (allocator_field or io_field) {
            try w.writeAll("\"#e8f5e9\", color=\"#1a7f37\"");
        } else {
            try w.writeAll("\"#eef2f7\", color=\"#8c959f\"");
        }
        const label = try std.fmt.allocPrint(gpa, "{s}\n{d} fields", .{ t.name, t.fields.items.len });
        try w.writeAll(", label=");
        try dotStr(w, label);
        try w.writeAll(", tooltip=");
        try dotStr(w, model_ptr.fileLabel(t.file));
        try w.writeAll("];\n");
    }

    for (model_ptr.fns.items, 0..) |f, fn_idx| {
        if (!fn_used[fn_idx]) continue;
        const label = try std.fmt.allocPrint(gpa, "{s}\n{s}:{d}", .{ f.name, model_ptr.fileLabel(f.file), f.line });
        try w.print("  fn{d} [fillcolor=\"#f3e8fd\", color=\"#8250df\", label=", .{fn_idx});
        try dotStr(w, label);
        try w.writeAll(", tooltip=");
        try dotStr(w, model_ptr.fileLabel(f.file));
        try w.writeAll("];\n");
    }

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    for (model_ptr.field_accesses.items) |access| {
        const key = try std.fmt.allocPrint(gpa, "{d}:{d}:{d}:{d}", .{
            access.fn_idx,
            access.type_id,
            access.field_id,
            @backingInt(access.kind),
        });
        const gop = try seen.getOrPut(gpa, key);
        if (gop.found_existing) continue;

        const field = model_ptr.fields.items[access.field_id];
        const fn_info = model_ptr.fns.items[access.fn_idx];
        const label = switch (access.kind) {
            .read => try std.fmt.allocPrint(gpa, "read {s}", .{field.name}),
            .write => try std.fmt.allocPrint(gpa, "write {s}", .{field.name}),
            .read_write => try std.fmt.allocPrint(gpa, "read+write {s}", .{field.name}),
        };
        try w.print("  fn{d} -> ty{d} [label=", .{ access.fn_idx, access.type_id });
        try dotStr(w, label);
        try w.writeAll(", color=");
        try w.writeAll(switch (access.kind) {
            .read => "\"#1a73e8\"",
            .write => "\"#d93025\"",
            .read_write => "\"#8250df\"",
        });
        try w.writeAll(", tooltip=");
        const tip = try std.fmt.allocPrint(gpa, "{s}:{d}", .{ model_ptr.fileLabel(fn_info.file), access.line });
        try dotStr(w, tip);
        try w.writeAll("];\n");
    }

    try w.writeAll("}\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

fn lessDebt(model_ptr: *Model, a: u32, b: u32) bool {
    return model_ptr.fns.items[a].debt_min > model_ptr.fns.items[b].debt_min;
}

fn lessFileDebt(model_ptr: *Model, a: u32, b: u32) bool {
    return model_ptr.files.items[a].debt_min > model_ptr.files.items[b].debt_min;
}

fn lessFieldActivity(model_ptr: *Model, a: u32, b: u32) bool {
    const fa = model_ptr.fields.items[a];
    const fb = model_ptr.fields.items[b];
    return (fa.reads + fa.writes) > (fb.reads + fb.writes);
}

fn plural(n: usize, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

fn htmlEscape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&#39;"),
            else => try w.writeByte(c),
        }
    }
}

fn writeFindings(model_ptr: *Model, w: *std.Io.Writer) !void {
    try w.writeAll("<section><h2>Findings</h2>\n");
    if (model_ptr.findings.items.len == 0) {
        try w.writeAll("<p class=\"muted\">None.</p></section>\n");
        return;
    }

    try w.writeAll("<div class=\"table-wrap\"><table><thead><tr><th>Severity</th><th>Rule</th><th>Location</th><th>Message</th><th>Source</th></tr></thead><tbody>\n");
    for (model_ptr.findings.items) |finding| {
        const pill = switch (finding.severity) {
            .@"error" => "red",
            .warning => "orange",
            .note => "",
        };
        try w.print("<tr><td><span class=\"pill {s}\">{s}</span></td><td class=\"mono\">", .{
            pill,
            @tagName(finding.severity),
        });
        try htmlEscape(w, finding.rule_id);
        try w.writeAll("</td><td class=\"mono\">");
        if (model_ptr.fileIndexByPath(finding.path)) |file_idx| {
            try htmlEscape(w, model_ptr.fileLabel(file_idx));
        } else {
            try htmlEscape(w, finding.path);
        }
        if (finding.line > 0) try w.print(":{d}", .{finding.line});
        try w.writeAll("</td><td>");
        try htmlEscape(w, finding.message);
        if (finding.suppressed) {
            try w.writeAll(" <span class=\"pill\">suppressed");
            if (finding.suppression_reason) |reason| {
                try w.writeAll(": ");
                try htmlEscape(w, reason);
            }
            try w.writeAll("</span>");
        }
        try w.print("</td><td>{s}</td></tr>\n", .{@tagName(finding.source)});
    }
    try w.writeAll("</tbody></table></div></section>\n");
}

fn writeHtml(
    model_ptr: *Model,
    io: Io,
    w: *std.Io.Writer,
    calls_svg: []const u8,
    fields_svg: []const u8,
    imports_rendered: bool,
    calls_rendered: bool,
    fields_rendered: bool,
    dependency_json: []const u8,
) !void {
    const s = model_ptr.settings;
    var total_loc: u32 = 0;
    for (model_ptr.fns.items) |f| total_loc += f.loc;

    const hours = @as(f64, @floatFromInt(model_ptr.total_debt)) / 60.0;
    const days = hours / 6.0;

    try w.writeAll("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try htmlEscape(w, model_ptr.title);
    try w.writeAll(" — zigdepends</title>\n<style>\n");
    try w.writeAll(
        \\:root{--bg:#fff;--fg:#1f2328;--muted:#6a737d;--line:#d8dee4;--panel:#f6f8fa;--accent:#8250df;--red:#d93025;--orange:#e37400;--green:#1a7f37}
        \\*{box-sizing:border-box}
        \\body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 Helvetica,Arial,sans-serif}
        \\header{padding:28px 36px 18px;border-bottom:1px solid var(--line);background:linear-gradient(180deg,#faf5ff,#fff)}
        \\h1{margin:2px 0 4px;font-size:26px;letter-spacing:-.02em}
        \\h2{font-size:18px;margin:0 0 12px}
        \\h3{font-size:14px;margin:18px 0 8px}
        \\main{max-width:1280px;margin:0 auto;padding:24px 36px 60px}
        \\.eyebrow{color:var(--accent);font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;margin:0}
        \\.root{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;margin:0}
        \\.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:26px}
        \\.card{border:1px solid var(--line);border-radius:10px;padding:12px 14px;background:var(--panel)}
        \\.card b{display:block;font-size:22px;line-height:1.2}
        \\.card span{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.06em}
        \\.card.hot{border-color:#f0c2bd;background:#fff8f7}
        \\.card.warn{border-color:#f2d3a4;background:#fffaf0}
        \\section{border:1px solid var(--line);border-radius:12px;padding:20px;margin:0 0 22px;background:#fff}
        \\table{width:100%;border-collapse:collapse;font-size:12px}
        \\th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--line);vertical-align:top}
        \\th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.05em;cursor:pointer;user-select:none;white-space:nowrap;position:sticky;top:0;background:#fff;z-index:1}
        \\.table-wrap{max-height:62vh;overflow:auto;border:1px solid var(--line);border-radius:8px}
        \\.table-wrap table{font-size:12px}
        \\tr:last-child td{border-bottom:0}
        \\tbody tr:hover{background:#fafbfc}
        \\code,.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:11.5px}
        \\.muted{color:var(--muted)}
        \\.pill{display:inline-block;border-radius:999px;padding:1px 7px;font-size:10px;border:1px solid var(--line);margin-right:3px;color:var(--muted);white-space:nowrap}
        \\.pill.red{border-color:#f0c2bd;background:#fff1f0;color:var(--red)}
        \\.pill.orange{border-color:#f2d3a4;background:#fff8e8;color:var(--orange)}
        \\.pill.purple{border-color:#d8c2f5;background:#faf5ff;color:var(--accent)}
        \\.pill.blue{border-color:#b6d7ff;background:#f0f7ff;color:#1a5fb4}
        \\.pill.green{border-color:#b7e1c1;background:#f0fff4;color:var(--green)}
        \\.score{font-weight:700;white-space:nowrap}
        \\.score.red{color:var(--red)}
        \\.score.orange{color:var(--orange)}
        \\.cycle{border-left:3px solid var(--red);background:#fffafa;padding:8px 12px;margin:8px 0;border-radius:0 8px 8px 0}
        \\.cycle.import{border-left-color:var(--orange);background:#fffaf2}
        \\.chain{display:flex;flex-wrap:wrap;align-items:center;gap:4px;margin:6px 0 12px;font-size:12px}
        \\.chain .node{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:2px 6px}
        \\.chain .arrow{color:var(--muted)}
        \\.graph-shell{margin:8px 0 18px}
        \\.graph-tools{display:flex;align-items:center;gap:6px;margin-bottom:6px;flex-wrap:wrap}
        \\.graph-tools button{border:1px solid var(--line);background:#fff;color:var(--fg);border-radius:6px;padding:3px 9px;font:12px Helvetica,Arial,sans-serif;cursor:pointer}
        \\.graph-tools button:hover{background:var(--panel);border-color:#b6a2d8}
        \\.graph-tools .hint{color:var(--muted);font-size:11px;margin-left:auto}
        \\.graph{border:1px solid var(--line);border-radius:8px;background:#fff;overflow:hidden;padding:0;height:76vh;min-height:440px;position:relative;touch-action:none}
        \\.graph svg{width:100%;height:100%;display:block;cursor:grab;user-select:none}
        \\.graph.dragging svg{cursor:grabbing}
        \\.graph-interactive .graph-file text,.graph-interactive .graph-group text{pointer-events:none}
        \\.graph-interactive .graph-header{cursor:pointer}
        \\.graph-interactive .graph-node{cursor:grab}
        \\.graph-interactive .graph-node.dragging{cursor:grabbing}
        \\.graph-interactive .graph-edge{pointer-events:none}
        \\.graph-links{font-size:11px;margin:-4px 0 10px}
        \\.graph-links a{color:var(--accent);text-decoration:none;margin-right:10px}
        \\.toolbar{display:flex;gap:8px;align-items:center;margin-bottom:10px;flex-wrap:wrap}
        \\input[type=search]{border:1px solid var(--line);border-radius:7px;padding:6px 9px;font:12px Helvetica,Arial,sans-serif;min-width:220px}
        \\footer{color:var(--muted);font-size:11px;padding:0 36px 30px;max-width:1280px;margin:0 auto}
        \\.cols{display:grid;grid-template-columns:1fr 1fr;gap:18px}
        \\@media(max-width:900px){.cols{grid-template-columns:1fr}header,main,footer{padding-left:18px;padding-right:18px}}
    );
    try w.writeAll("</style></head><body>\n<header>\n<p class=\"eyebrow\">zigdepends</p>\n<h1>");
    try htmlEscape(w, model_ptr.title);
    try w.writeAll("</h1>\n<p class=\"root\">");
    try htmlEscape(w, model_ptr.root);
    try w.writeAll("</p>\n</header>\n<main>\n");

    // Cards.
    var source_files: usize = 0;
    var generated_files: usize = 0;
    for (model_ptr.files.items) |file| {
        if (file.generated) generated_files += 1 else source_files += 1;
    }
    try w.writeAll("<div class=\"cards\">\n");
    try card(w, "Source files", source_files, false, false);
    try card(w, "Generated", generated_files, false, false);
    try card(w, "Functions", model_ptr.fns.items.len, false, false);
    try card(w, "Function LOC", total_loc, false, false);
    try w.writeAll("<div class=\"card");
    if (model_ptr.import_cycles.items.len > 0) try w.writeAll(" hot");
    try w.writeAll("\"><b>");
    try w.print("{d}</b><span>{s}</span></div>\n", .{
        model_ptr.import_cycles.items.len,
        if (model_ptr.import_cycles.items.len == 1) "import cycle" else "import cycles",
    });
    try w.writeAll("<div class=\"card");
    if (model_ptr.call_cycles.items.len > 0) try w.writeAll(" warn");
    try w.writeAll("\"><b>");
    try w.print("{d}</b><span>{s}</span></div>\n", .{
        model_ptr.call_cycles.items.len,
        if (model_ptr.call_cycles.items.len == 1) "recursion group" else "recursion groups",
    });
    try w.writeAll("<div class=\"card warn\"><b>");
    try w.print("{d:.1}h", .{hours});
    try w.writeAll("</b><span>debt · ");
    try w.print("{d:.1}", .{days});
    try w.writeAll(" dev-days</span></div>\n");
    try card(w, "Unresolved calls", model_ptr.unresolved_calls, false, false);
    try w.writeAll("</div>\n");

    // Capabilities.
    if (model_ptr.config.track_capabilities) {
        var direct_alloc: u32 = 0;
        var direct_io: u32 = 0;
        var inherited_caps: u32 = 0;
        var pure: u32 = 0;
        var hidden: u32 = 0;
        var debug_prints: u32 = 0;
        for (model_ptr.fns.items) |f| {
            if (f.sig_allocator or f.direct_allocator) direct_alloc += 1;
            if (f.sig_io or f.direct_io) direct_io += 1;
            if (f.inherited_allocator or f.inherited_io) inherited_caps += 1;
            if (!f.needs_allocator and !f.needs_io) pure += 1;
            if ((f.needs_allocator and f.alloc_source == .inherited) or
                (f.needs_io and f.io_source == .inherited)) hidden += 1;
            if (f.debug_io) debug_prints += 1;
        }

        try w.writeAll("<section><h2>Capabilities</h2>\n");
        try w.writeAll("<p class=\"muted\">Direct requirements come from signatures and allocator/Io calls; inherited requirements are propagated through the call graph (callee → caller). Debug prints are tracked separately and only count as Io with <code>--debug-io</code>.</p>\n");
        try w.writeAll("<div class=\"cards\">\n");
        try card(w, "Direct allocator", direct_alloc, false, false);
        try card(w, "Direct Io", direct_io, false, false);
        try card(w, "Inherited", inherited_caps, false, false);
        try card(w, "Pure", pure, false, false);
        try card(w, "Unattributed", hidden, false, true);
        try card(w, "Debug prints", debug_prints, false, false);
        try w.writeAll("</div>\n");

        try w.writeAll("<div class=\"cols\"><div><h3>Entry points</h3>\n");
        if (model_ptr.chains.items.len == 0) {
            try w.writeAll("<p class=\"muted\">No entry points detected.</p>\n");
        } else {
            for (model_ptr.chains.items) |chain| {
                const f = model_ptr.fns.items[chain.root];
                try w.writeAll("<div class=\"chain\"><span class=\"node mono\">");
                try htmlEscape(w, model_ptr.fileLabel(f.file));
                try w.writeAll(" / ");
                try htmlEscape(w, f.name);
                try w.writeAll("</span>");
                try capabilityPills(w, f);
                try w.writeAll("</div>\n");
            }
        }
        try w.writeAll("</div><div><h3>Unattributed requirements</h3>\n");
        if (hidden == 0) {
            try w.writeAll("<p class=\"muted\">None. Every inherited requirement has a visible parameter, field, or local source.</p>\n");
        } else {
            try w.writeAll("<p class=\"muted\">Needs allocator/Io through calls, but the source is not a direct parameter, known field, or local. This is an analysis gap, not a Zig runtime feature — check context structs, nested fields, generics, and external types.</p>\n");
            var hidden_shown: u32 = 0;
            for (model_ptr.fns.items, 0..) |f, idx| {
                if (hidden_shown >= 40) break;
                const alloc_hidden = f.needs_allocator and f.alloc_source == .inherited;
                const io_hidden = f.needs_io and f.io_source == .inherited;
                if (!alloc_hidden and !io_hidden) continue;
                hidden_shown += 1;
                try w.writeAll("<div class=\"chain\"><span class=\"mono\">");
                try htmlEscape(w, f.name);
                try w.writeAll("</span><span class=\"muted mono\">");
                try htmlEscape(w, model_ptr.fileLabel(f.file));
                try w.print(":{d}", .{f.line});
                try w.writeAll("</span>");
                if (alloc_hidden) try w.writeAll("<span class=\"pill blue\">alloc*</span>");
                if (io_hidden) try w.writeAll("<span class=\"pill orange\">io*</span>");
                try w.writeAll("</div>\n");
                _ = idx;
            }
        }
        try w.writeAll("</div></div>\n");

        // Capability table, highest debt first.
        try w.writeAll("<h3>Functions with requirements</h3>\n<div class=\"table-wrap\"><table><thead><tr><th>Function</th><th>Location</th><th>Allocator</th><th>Io</th><th>Source</th></tr></thead><tbody>\n");
        var cap_order = try model_ptr.gpa.alloc(u32, model_ptr.fns.items.len);
        for (0..cap_order.len) |idx| cap_order[idx] = @intCast(idx);
        std.mem.sort(u32, cap_order, model_ptr, lessDebt);
        var cap_shown: usize = 0;
        for (cap_order) |fn_idx| {
            const f = model_ptr.fns.items[fn_idx];
            if (!f.needs_allocator and !f.needs_io) continue;
            if (cap_shown >= 250) break;
            cap_shown += 1;
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, f.name);
            try w.writeAll("</td><td class=\"mono muted\">");
            try htmlEscape(w, model_ptr.fileLabel(f.file));
            try w.print(":{d}</td><td>", .{f.line});
            try capabilityCell(w, f, true);
            try w.writeAll("</td><td>");
            try capabilityCell(w, f, false);
            try w.writeAll("</td><td class=\"muted\">");
            var wrote_source = false;
            if (f.needs_allocator) {
                try htmlEscape(w, sourceLabel(f.alloc_source));
                wrote_source = true;
            }
            if (f.needs_io) {
                if (wrote_source) try w.writeAll(" / ");
                try htmlEscape(w, sourceLabel(f.io_source));
                wrote_source = true;
            }
            if (!wrote_source) try w.writeAll("<span class=\"muted\">—</span>");
            try w.writeAll("</td></tr>\n");
        }
        if (cap_shown == 0) try w.writeAll("<tr><td colspan=\"5\" class=\"muted\">No functions require allocator or Io.</td></tr>\n");
        try w.writeAll("</tbody></table></div></section>\n");
    }

    if (model_ptr.config.track_fields) {
        var allocator_types: u32 = 0;
        var io_types: u32 = 0;
        var pointer_types: u32 = 0;
        var no_deinit: u32 = 0;
        for (model_ptr.types.items) |t| {
            var has_alloc_field = false;
            var has_io_field = false;
            var has_pointer = false;
            for (t.fields.items) |field_id| {
                const field = model_ptr.fields.items[field_id];
                if (field.is_allocator) has_alloc_field = true;
                if (field.is_io) has_io_field = true;
                if (field.is_pointer or field.is_slice) has_pointer = true;
            }
            if (has_alloc_field) allocator_types += 1;
            if (has_io_field) io_types += 1;
            if (has_pointer) pointer_types += 1;
            if ((has_alloc_field or has_io_field) and !t.has_deinit) no_deinit += 1;
        }

        try w.writeAll("<section><h2>Object ownership &amp; field access</h2>\n");
        try w.writeAll("<p class=\"muted\">Field access is resolved through <code>self</code>, typed parameters/locals, and nested fields. Ownership markers are signals, not verification: allocator/Io fields, pointer/slice fields, and init/deinit candidates.</p>\n");
        try w.writeAll("<div class=\"cards\">\n");
        try card(w, "Types", model_ptr.types.items.len, false, false);
        try card(w, "Fields", model_ptr.fields.items.len, false, false);
        try card(w, "Field accesses", model_ptr.field_accesses.items.len, false, false);
        try card(w, "Allocator types", allocator_types, false, false);
        try card(w, "Io types", io_types, false, false);
        try card(w, "No deinit", no_deinit, false, true);
        try w.writeAll("</div>\n");

        // Ownership signals.
        if (no_deinit > 0) {
            try w.writeAll("<h3>Ownership signals</h3><p class=\"muted\">Types with an allocator/Io field but no detected <code>deinit</code>/<code>destroy</code>/<code>free</code> method.</p><div class=\"chain\">\n");
            var shown_signals: u32 = 0;
            for (model_ptr.types.items) |t| {
                if (shown_signals >= 30) break;
                var has_alloc_field = false;
                var has_io_field = false;
                for (t.fields.items) |field_id| {
                    const field = model_ptr.fields.items[field_id];
                    if (field.is_allocator) has_alloc_field = true;
                    if (field.is_io) has_io_field = true;
                }
                if (!(has_alloc_field or has_io_field) or t.has_deinit) continue;
                shown_signals += 1;
                try w.writeAll("<span class=\"node mono\">");
                try htmlEscape(w, t.name);
                try w.writeAll(" <span class=\"muted\">");
                try htmlEscape(w, model_ptr.fileLabel(t.file));
                try w.print(":{d}</span></span>", .{t.line});
            }
            try w.writeAll("</div>\n");
        }

        // Type table.
        try w.writeAll("<h3>Types</h3><div class=\"table-wrap\"><table><thead><tr><th>Type</th><th>Location</th><th data-sort=\"num\">Fields</th><th data-sort=\"num\">Reads</th><th data-sort=\"num\">Writes</th><th>Lifecycle</th></tr></thead><tbody>\n");
        for (model_ptr.types.items) |t| {
            var reads: u32 = 0;
            var writes: u32 = 0;
            var has_alloc_field = false;
            var has_io_field = false;
            var has_pointer = false;
            for (t.fields.items) |field_id| {
                const field = model_ptr.fields.items[field_id];
                reads += field.reads;
                writes += field.writes;
                if (field.is_allocator) has_alloc_field = true;
                if (field.is_io) has_io_field = true;
                if (field.is_pointer or field.is_slice) has_pointer = true;
            }
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, t.name);
            try w.writeAll("</td><td class=\"mono muted\">");
            try htmlEscape(w, model_ptr.fileLabel(t.file));
            try w.print(":{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>", .{ t.line, t.fields.items.len, reads, writes });
            if (t.has_init) try w.writeAll("<span class=\"pill green\">init</span>");
            if (t.has_deinit) try w.writeAll("<span class=\"pill purple\">deinit</span>");
            if (has_alloc_field) try w.writeAll("<span class=\"pill blue\">alloc field</span>");
            if (has_io_field) try w.writeAll("<span class=\"pill orange\">io field</span>");
            if (has_pointer) try w.writeAll("<span class=\"pill\">pointer/slice</span>");
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody></table></div>\n");

        // Top fields.
        var field_order = try model_ptr.gpa.alloc(u32, model_ptr.fields.items.len);
        for (0..field_order.len) |i| field_order[i] = @intCast(i);
        std.mem.sort(u32, field_order, model_ptr, lessFieldActivity);
        try w.writeAll("<h3>Most accessed fields</h3><div class=\"table-wrap\"><table><thead><tr><th>Field</th><th>Type</th><th data-sort=\"num\">Reads</th><th data-sort=\"num\">Writes</th><th>Shape</th></tr></thead><tbody>\n");
        var field_shown: usize = 0;
        for (field_order) |field_id| {
            const field = model_ptr.fields.items[field_id];
            if (field.reads + field.writes == 0) break;
            if (field_shown >= 100) break;
            field_shown += 1;
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, field.name);
            try w.writeAll("</td><td class=\"mono muted\">");
            try htmlEscape(w, field.container);
            try w.print("</td><td>{d}</td><td>{d}</td><td>", .{ field.reads, field.writes });
            if (field.is_allocator) try w.writeAll("<span class=\"pill blue\">allocator</span>");
            if (field.is_io) try w.writeAll("<span class=\"pill orange\">io</span>");
            if (field.is_pointer) try w.writeAll("<span class=\"pill\">pointer</span>");
            if (field.is_slice) try w.writeAll("<span class=\"pill\">slice</span>");
            try w.writeAll("</td></tr>\n");
        }
        if (field_shown == 0) try w.writeAll("<tr><td colspan=\"5\" class=\"muted\">No resolved field accesses.</td></tr>\n");
        try w.writeAll("</tbody></table></div>\n");

        try w.writeAll("<h3>Field access graph</h3><p class=\"graph-links\"><a href=\"fields.svg\">fields.svg</a><a href=\"fields.dot\">fields.dot</a></p>\n<p class=\"muted\">Blue = read, red = write, purple = read+write. Types with allocator/Io fields are green.</p>\n");
        try writeGraphBlock(w, io, fields_svg, fields_rendered);
        try w.writeAll("</section>\n");
    }

    // Debt table.
    try w.writeAll("<section><h2>Technical debt</h2>\n");
    try w.print("<p class=\"muted\">Findings estimate: {d} minutes total — {d} zlint, {d} project. Assumes 6 productive hours per dev-day.</p>\n", .{
        model_ptr.total_debt,
        model_ptr.zlint_debt,
        model_ptr.project_debt,
    });
    try w.writeAll("<div class=\"toolbar\"><input type=\"search\" id=\"debt-filter\" placeholder=\"filter functions…\"><span class=\"muted\">Click a header to sort. Showing up to 250 highest-debt functions.</span></div>\n");
    try w.writeAll("<div class=\"table-wrap\"><table id=\"debt-table\"><thead><tr><th data-sort=\"num\">Score</th><th>Function</th><th>Location</th><th data-sort=\"num\">LOC</th><th data-sort=\"num\">Cx</th><th data-sort=\"num\">Nest</th><th data-sort=\"num\">Params</th><th>Flags</th></tr></thead><tbody>\n");

    var order = try model_ptr.gpa.alloc(u32, model_ptr.fns.items.len);
    for (0..order.len) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, model_ptr, lessDebt);
    var shown: usize = 0;
    for (order) |fn_idx| {
        const f = model_ptr.fns.items[fn_idx];
        if (f.debt_min < s.min_debt) continue;
        if (f.debt_min == 0 and shown >= 40) break;
        if (shown >= 250) break;
        shown += 1;
        try w.writeAll("<tr><td class=\"score");
        if (f.debt_min >= 120) try w.writeAll(" red") else if (f.debt_min >= 60) try w.writeAll(" orange");
        try w.print("\">{d}</td><td class=\"mono\">", .{f.debt_min});
        try htmlEscape(w, f.name);
        try w.writeAll("</td><td class=\"mono muted\">");
        try htmlEscape(w, model_ptr.fileLabel(f.file));
        try w.print(":{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>{d}</td><td>", .{
            f.line,
            f.loc,
            f.complexity,
            f.nesting,
            f.params,
        });
        if (f.in_call_cycle) try w.writeAll("<span class=\"pill red\">call cycle</span>");
        if (model_ptr.config.track_capabilities) try capabilityPills(w, f);
        if (f.is_pub) try w.writeAll("<span class=\"pill purple\">pub</span>");
        try w.writeAll("</td></tr>\n");
    }
    if (shown == 0) try w.writeAll("<tr><td colspan=\"8\" class=\"muted\">No debt above the current threshold.</td></tr>\n");
    try w.writeAll("</tbody></table></div></section>\n");

    try writeFindings(model_ptr, w);

    // Cycles.
    try w.writeAll("<section><h2>Circular references</h2>\n<p class=\"muted\">Import cycles usually indicate architectural coupling. Call cycles are recursion; self-recursion is normal, mutual recursion is worth reviewing.</p>\n<div class=\"cols\"><div><h3>Import cycles</h3>\n");
    if (model_ptr.import_cycles.items.len == 0) {
        try w.writeAll("<p class=\"muted\">None found.</p>\n");
    } else {
        for (model_ptr.import_cycles.items, 0..) |cycle, i| {
            try w.writeAll("<div class=\"cycle import\"><strong>Import cycle ");
            try w.print("{d}</strong> <span class=\"muted\">({d} {s})</span><br>", .{ i + 1, cycle.nodes.len, plural(cycle.nodes.len, "file", "files") });
            for (cycle.nodes, 0..) |file_idx, j| {
                if (j != 0) try w.writeAll(", ");
                try w.writeAll("<span class=\"mono\">");
                try htmlEscape(w, model_ptr.fileLabel(file_idx));
                try w.writeAll("</span>");
            }
            try w.writeAll("</div>\n");
        }
    }
    try w.writeAll("</div><div><h3>Call cycles</h3>\n");
    if (model_ptr.call_cycles.items.len == 0) {
        try w.writeAll("<p class=\"muted\">None found.</p>\n");
    } else {
        for (model_ptr.call_cycles.items, 0..) |cycle, i| {
            try w.writeAll("<div class=\"cycle\"><strong>");
            if (cycle.nodes.len == 1) {
                try w.writeAll("Self-recursion");
            } else {
                try w.writeAll("Mutual recursion");
            }
            try w.writeAll(" ");
            try w.print("{d}</strong> <span class=\"muted\">({d} {s})</span><br>", .{ i + 1, cycle.nodes.len, plural(cycle.nodes.len, "function", "functions") });
            for (cycle.nodes, 0..) |fn_idx, j| {
                const f = model_ptr.fns.items[fn_idx];
                if (j != 0) try w.writeAll(", ");
                try w.writeAll("<span class=\"mono\">");
                try htmlEscape(w, f.name);
                try w.writeAll("</span> <span class=\"muted mono\">");
                try htmlEscape(w, model_ptr.fileLabel(f.file));
                try w.print(":{d}", .{f.line});
                try w.writeAll("</span>");
            }
            try w.writeAll("</div>\n");
        }
    }
    try w.writeAll("</div></div></section>\n");

    // Chains.
    try w.writeAll("<section><h2>Call stacks</h2>\n");
    if (model_ptr.chains.items.len == 0) {
        try w.writeAll("<p class=\"muted\">No entry points found (looked for <code>main</code>, then pub functions with no callers).</p>\n");
    } else {
        try w.writeAll("<p class=\"muted\">Longest simple call chains from entry points. Static resolution only; dynamic calls are omitted.</p>\n");
        for (model_ptr.chains.items) |chain| {
            const root = model_ptr.fns.items[chain.root];
            try w.writeAll("<div class=\"chain\"><span class=\"pill purple\">");
            try htmlEscape(w, model_ptr.fileLabel(root.file));
            try w.writeAll("</span>");
            for (chain.nodes, 0..) |fn_idx, i| {
                if (i != 0) try w.writeAll("<span class=\"arrow\">→</span>");
                const f = model_ptr.fns.items[fn_idx];
                try w.writeAll("<span class=\"node mono\" title=\"");
                try htmlEscape(w, model_ptr.fileLabel(f.file));
                try w.print(":{d}", .{f.line});
                try w.writeAll("\">");
                try htmlEscape(w, f.name);
                try w.writeAll("</span>");
            }
            try w.print("<span class=\"muted\">({d} calls deep)</span></div>\n", .{chain.nodes.len - 1});
        }
    }
    try w.writeAll("</section>\n");

    // Graphs.
    try w.writeAll("<section id=\"dependency-graph\"><h2>Dependency graph</h2>\n");
    try w.writeAll("<p class=\"muted\">Files are grouped inside their facade and submodule containers. Click a container header to collapse or expand it, drag nodes to arrange the graph, and use the wheel to zoom.</p>\n");
    try w.writeAll("<p class=\"graph-links\"><a href=\"imports.dot\">imports.dot</a>");
    if (imports_rendered) try w.writeAll("<a href=\"imports.svg\">static imports.svg</a>");
    try w.writeAll("</p>\n");
    if (model_ptr.config.graph_exclude.items.len > 0) {
        try w.writeAll("<p class=\"muted\">Excluded from this graph: ");
        for (model_ptr.config.graph_exclude.items, 0..) |pattern, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll("<code>");
            try htmlEscape(w, pattern);
            try w.writeAll("</code>");
        }
        try w.writeAll(".</p>\n");
    }
    try w.writeAll("<div class=\"graph-shell\"><div class=\"graph-tools\">\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"zoom-out\" title=\"Zoom out\">&minus;</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"zoom-in\" title=\"Zoom in\">+</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"fit\" title=\"Fit all visible nodes\">Fit</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"reset\" title=\"Reset layout and zoom\">Reset</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"collapse\" title=\"Collapse every facade\">Collapse all</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-command=\"expand\" title=\"Expand every facade\">Expand all</button>\n");
    try w.writeAll("<span class=\"hint\">Click a facade header to collapse · drag nodes to arrange · wheel to zoom</span>\n");
    try w.writeAll("</div><div class=\"graph graph-interactive\" data-dependency-graph></div></div>\n");
    try w.writeAll("<p class=\"muted\">Red = import cycle, dashed gray = generated target, dashed amber = unresolved module import. Edge labels count aggregated imports when containers are collapsed.</p>\n");
    try w.writeAll("</section>\n<section><h2>Call graph</h2>\n<p class=\"graph-links\"><a href=\"calls.svg\">calls.svg</a><a href=\"calls.dot\">calls.dot</a></p>\n<p class=\"muted\">Top functions by debt, plus every recursion and call-stack node. Red = recursion, amber = high debt.</p>\n");
    try writeGraphBlock(w, io, calls_svg, calls_rendered);
    try w.writeAll("</section>\n");

    // Files.
    try w.writeAll("<section><h2>Files</h2>\n<table><thead><tr><th>File</th><th data-sort=\"num\">Functions</th><th data-sort=\"num\">Debt</th><th data-sort=\"num\">Imports</th></tr></thead><tbody>\n");
    var file_order = try model_ptr.gpa.alloc(u32, model_ptr.files.items.len);
    for (0..file_order.len) |i| file_order[i] = @intCast(i);
    std.mem.sort(u32, file_order, model_ptr, lessFileDebt);
    for (file_order) |file_idx| {
        const file = model_ptr.files.items[file_idx];
        if (file.generated and !model_ptr.config.include_generated_metrics) continue;
        try w.writeAll("<tr><td class=\"mono\">");
        try htmlEscape(w, model_ptr.fileLabel(file_idx));
        if (file.generated) try w.writeAll(" <span class=\"pill\">generated</span>");
        try w.print("</td><td>{d}</td><td>{d}</td><td>{d}</td></tr>\n", .{
            file.fns.items.len,
            file.debt_min,
            file.imports.items.len,
        });
    }
    try w.writeAll("</tbody></table></section>\n");

    // Generated / excluded files.
    try w.writeAll("<section><h2>Generated and excluded files</h2>\n");
    if (generated_files == 0 and model_ptr.excluded_files.items.len == 0) {
        try w.writeAll("<p class=\"muted\">None.</p>\n");
    } else {
        if (model_ptr.config.include_generated_metrics) {
            try w.writeAll("<p class=\"muted\">Generated files are marked, but their function bodies are included because generated analysis is enabled.</p>\n");
        } else {
            try w.writeAll("<p class=\"muted\">Generated files contribute imports but are excluded from function, debt, capability, and field-access metrics. Use <code>--include-generated</code> to analyze their bodies.</p>\n");
        }
        try w.writeAll("<table><thead><tr><th>File</th><th>Status</th><th>Reason</th></tr></thead><tbody>\n");
        for (model_ptr.files.items, 0..) |file, file_idx| {
            if (!file.generated) continue;
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, model_ptr.fileLabel(@intCast(file_idx)));
            try w.writeAll("</td><td>");
            if (model_ptr.config.include_generated_metrics) {
                try w.writeAll("<span class=\"pill purple\">analyzed</span>");
            } else {
                try w.writeAll("<span class=\"pill\">boundary</span>");
            }
            try w.writeAll("</td><td class=\"muted\">");
            try htmlEscape(w, file.generated_reason orelse "generated");
            try w.writeAll("</td></tr>\n");
        }
        for (model_ptr.excluded_files.items) |skipped| {
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, skipped.path);
            try w.writeAll("</td><td><span class=\"pill orange\">excluded</span></td><td class=\"muted\">");
            try htmlEscape(w, skipped.reason);
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody></table>\n");
    }
    try w.writeAll("</section>\n");

    // Unresolved.
    try w.writeAll("<section><h2>Resolution limits</h2>\n<div class=\"cols\"><div><h3>Unresolved module imports</h3>\n");
    if (model_ptr.module_imports.items.len == 0) {
        try w.writeAll("<p class=\"muted\">None. All imports are relative files or std/builtin.</p>\n");
    } else {
        try w.writeAll("<p class=\"muted\">Module names require build.zig mapping; they are treated as external boundaries.</p><table><thead><tr><th>Module</th><th>File</th></tr></thead><tbody>\n");
        for (model_ptr.module_imports.items) |mi| {
            try w.writeAll("<tr><td class=\"mono\">");
            try htmlEscape(w, mi.raw);
            try w.writeAll("</td><td class=\"mono muted\">");
            try htmlEscape(w, model_ptr.fileLabel(mi.file));
            try w.print(":{d}</td></tr>\n", .{mi.line});
        }
        try w.writeAll("</tbody></table>\n");
    }
    try w.writeAll("</div><div><h3>Calls</h3>\n<p class=\"muted\">Resolved ");
    try w.print("{d}", .{model_ptr.resolved_calls});
    try w.writeAll(", unresolved internal ");
    try w.print("{d}", .{model_ptr.unresolved_calls});
    try w.writeAll(", external ");
    try w.print("{d}", .{model_ptr.external_calls});
    try w.writeAll(", ambiguous global names ");
    try w.print("{d}</p>\n", .{model_ptr.ambiguous_names});
    try w.writeAll("<p class=\"muted\">Comptime dispatch, function pointers, and calls through interface-like values are expected to remain unresolved.</p>\n");
    try w.writeAll("</div></div></section>\n");

    try w.writeAll("</main>\n<footer>Generated by zigdepends. Debt is computed from zlint and project findings. Weights are configurable, not measurements.</footer>\n");

    try w.writeAll(
        \\<script>
        \\const table=document.getElementById('debt-table');
        \\document.getElementById('debt-filter')?.addEventListener('input',e=>{
        \\  const q=e.target.value.toLowerCase();
        \\  table.querySelectorAll('tbody tr').forEach(r=>{r.style.display=r.textContent.toLowerCase().includes(q)?'':'none'});
        \\});
        \\document.querySelectorAll('th[data-sort]').forEach(th=>{
        \\  th.addEventListener('click',()=>{
        \\    const t=th.closest('table'),tb=t.tBodies[0],rows=[...tb.rows];
        \\    const i=th.cellIndex,dir=th.dataset.dir==='asc'?-1:1;
        \\    th.dataset.dir=dir===1?'asc':'desc';
        \\    rows.sort((a,b)=>{
        \\      const av=a.cells[i]?.textContent.trim()||'',bv=b.cells[i]?.textContent.trim()||'';
        \\      return th.dataset.sort==='num'?(parseFloat(av)-parseFloat(bv))*dir:av.localeCompare(bv)*dir;
        \\    });
        \\    rows.forEach(r=>tb.appendChild(r));
        \\  });
        \\});
        \\function clamp(v,lo,hi){return Math.max(lo,Math.min(hi,v));}
        \\function graphViewBox(svg){
        \\  if(svg.viewBox&&svg.viewBox.baseVal&&svg.viewBox.baseVal.width>0){
        \\    const vb=svg.viewBox.baseVal;
        \\    return {x:vb.x,y:vb.y,w:vb.width,h:vb.height};
        \\  }
        \\  const w=parseFloat(svg.getAttribute('width')||'0');
        \\  const h=parseFloat(svg.getAttribute('height')||'0');
        \\  return w>0&&h>0?{x:0,y:0,w:w,h:h}:null;
        \\}
        \\function setGraphView(svg,v){svg.setAttribute('viewBox',v.x+' '+v.y+' '+v.w+' '+v.h);}
        \\function focusBox(svg,el){
        \\  const b=el.getBBox();
        \\  if(!b||b.width<=0||b.height<=0)return null;
        \\  const ctm=el.getCTM(),root=svg.getCTM();
        \\  if(!ctm||!root)return null;
        \\  const m=root.inverse().multiply(ctm);
        \\  const pts=[[b.x,b.y],[b.x+b.width,b.y],[b.x,b.y+b.height],[b.x+b.width,b.y+b.height]].map(p=>{
        \\    const q=svg.createSVGPoint();q.x=p[0];q.y=p[1];return q.matrixTransform(m);
        \\  });
        \\  let x1=Infinity,y1=Infinity,x2=-Infinity,y2=-Infinity;
        \\  pts.forEach(p=>{x1=Math.min(x1,p.x);y1=Math.min(y1,p.y);x2=Math.max(x2,p.x);y2=Math.max(y2,p.y);});
        \\  return {x:x1,y:y1,w:x2-x1,h:y2-y1};
        \\}
        \\function graphHit(svg,box,view,x,y){
        \\  const r=box.getBoundingClientRect();
        \\  const s=Math.min(r.width/view.w,r.height/view.h)||1;
        \\  const ox=(r.width-view.w*s)/2,oy=(r.height-view.h*s)/2;
        \\  const toClient=(px,py)=>({x:r.left+ox+(px-view.x)*s,y:r.top+oy+(py-view.y)*s});
        \\  let best=null,bestArea=Infinity;
        \\  svg.querySelectorAll('g.node, g.cluster').forEach(el=>{
        \\    const b=focusBox(svg,el);
        \\    if(!b||b.w<=0||b.h<=0)return;
        \\    const p1=toClient(b.x,b.y),p2=toClient(b.x+b.w,b.y+b.h);
        \\    if(x<p1.x||x>p2.x||y<p1.y||y>p2.y)return;
        \\    const area=b.w*b.h;
        \\    if(area<bestArea){best=el;bestArea=area;}
        \\  });
        \\  return best;
        \\}
        \\function initGraph(box){
        \\  const svg=box.querySelector('svg');
        \\  if(!svg)return;
        \\  const initial=graphViewBox(svg);
        \\  if(!initial)return;
        \\  svg.removeAttribute('width');
        \\  svg.removeAttribute('height');
        \\  let view=fitView();
        \\  const minW=Math.max(initial.w/50,0.01),maxW=initial.w*10;
        \\  function apply(){setGraphView(svg,view);}
        \\  function fitView(){
        \\    const r=box.getBoundingClientRect();
        \\    if(r.width<=0||r.height<=0)return {x:initial.x,y:initial.y,w:initial.w,h:initial.h};
        \\    const fitH=initial.w*r.height/r.width;
        \\    if(initial.h<=fitH)return {x:initial.x,y:initial.y,w:initial.w,h:initial.h};
        \\    return {x:initial.x,y:initial.y,w:initial.w,h:fitH};
        \\  }
        \\  function pointAt(e){
        \\    const r=box.getBoundingClientRect();
        \\    const s=Math.min(r.width/view.w,r.height/view.h)||1;
        \\    const ox=(r.width-view.w*s)/2,oy=(r.height-view.h*s)/2;
        \\    return {x:view.x+(e.clientX-r.left-ox)/s,y:view.y+(e.clientY-r.top-oy)/s};
        \\  }
        \\  function zoomAt(px,py,factor){
        \\    const nw=clamp(view.w*factor,minW,maxW);
        \\    const k=nw/view.w;
        \\    view.x=px-(px-view.x)*k;
        \\    view.y=py-(py-view.y)*k;
        \\    view.w=nw;
        \\    view.h*=k;
        \\    apply();
        \\  }
        \\  box.addEventListener('wheel',e=>{
        \\    e.preventDefault();
        \\    const p=pointAt(e);
        \\    zoomAt(p.x,p.y,e.deltaY<0?0.82:1.22);
        \\  },{passive:false});
        \\  let drag=null;
        \\  svg.addEventListener('pointerdown',e=>{
        \\    if(e.button!==0)return;
        \\    drag={sx:e.clientX,sy:e.clientY,x:view.x,y:view.y,moved:false,id:e.pointerId};
        \\  });
        \\  svg.addEventListener('pointermove',e=>{
        \\    if(!drag)return;
        \\    if(!drag.moved){
        \\      if(Math.abs(e.clientX-drag.sx)+Math.abs(e.clientY-drag.sy)<3)return;
        \\      drag.moved=true;
        \\      svg.setPointerCapture(drag.id);
        \\      box.classList.add('dragging');
        \\    }
        \\    const r=box.getBoundingClientRect();
        \\    const s=Math.min(r.width/view.w,r.height/view.h)||1;
        \\    view.x=drag.x-(e.clientX-drag.sx)/s;
        \\    view.y=drag.y-(e.clientY-drag.sy)/s;
        \\    apply();
        \\  });
        \\  function endDrag(){
        \\    if(!drag)return;
        \\    if(drag.moved){try{svg.releasePointerCapture(drag.id);}catch(_){}}
        \\    drag=null;
        \\    box.classList.remove('dragging');
        \\  }
        \\  svg.addEventListener('pointerup',endDrag);
        \\  svg.addEventListener('pointercancel',endDrag);
        \\  svg.addEventListener('dblclick',e=>{
        \\    let target=e.target.closest?e.target.closest('g.node, g.cluster'):null;
        \\    if(!target)target=graphHit(svg,box,view,e.clientX,e.clientY);
        \\    if(!target)return;
        \\    const part=focusBox(svg,target);
        \\    if(!part)return;
        \\    const pad=Math.max(part.w,part.h)*0.12;
        \\    view={x:part.x-pad,y:part.y-pad,w:part.w+pad*2,h:part.h+pad*2};
        \\    apply();
        \\    e.preventDefault();
        \\  });
        \\  const shell=box.parentElement;
        \\  if(shell){
        \\    shell.querySelectorAll('[data-graph-action]').forEach(btn=>{
        \\      btn.addEventListener('click',()=>{
        \\        const action=btn.getAttribute('data-graph-action');
        \\        if(action==='reset'){view=fitView();apply();return;}
        \\        zoomAt(view.x+view.w/2,view.y+view.h/2,action==='in'?0.72:1.38);
        \\      });
        \\    });
        \\  }
        \\  apply();
        \\}
        \\document.querySelectorAll('.graph[data-graph]').forEach(initGraph);
        \\</script>
        \\<script>window.dependencyGraphData = 
    );
    try w.writeAll(dependency_json);
    try w.writeAll(";\n</script>\n<script>\n");
    try w.writeAll(graph_view_js);
    try w.writeAll("\n</script>\n</body></html>\n");
}

fn capabilityPills(w: *std.Io.Writer, f: model.FnInfo) !void {
    if (f.needs_allocator) {
        const inherited = f.alloc_source == .inherited and !f.sig_allocator and !f.direct_allocator;
        try w.writeAll("<span class=\"pill blue\" title=\"allocator requirement\">");
        try w.writeAll(if (inherited) "alloc*" else "alloc");
        try w.writeAll("</span>");
    }
    if (f.needs_io) {
        const inherited = f.io_source == .inherited and !f.sig_io and !f.direct_io;
        try w.writeAll("<span class=\"pill orange\" title=\"Io requirement\">");
        try w.writeAll(if (inherited) "io*" else "io");
        try w.writeAll("</span>");
    }
    if (!f.needs_allocator and !f.needs_io) {
        try w.writeAll("<span class=\"pill green\">pure</span>");
    }
    if (f.debug_io) try w.writeAll("<span class=\"pill\">debug</span>");
}

fn capabilityCell(w: *std.Io.Writer, f: model.FnInfo, allocator: bool) !void {
    if (allocator) {
        if (f.sig_allocator or f.direct_allocator) {
            try w.writeAll(if (f.inherited_allocator) "direct + inherited" else "direct");
        } else if (f.needs_allocator) {
            try w.writeAll("inherited");
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
    } else {
        if (f.sig_io or f.direct_io) {
            try w.writeAll(if (f.inherited_io) "direct + inherited" else "direct");
        } else if (f.needs_io) {
            try w.writeAll("inherited");
        } else {
            try w.writeAll("<span class=\"muted\">—</span>");
        }
    }
}

fn sourceLabel(source: model.CapSource) []const u8 {
    return switch (source) {
        .none => "none",
        .param => "param",
        .field => "field",
        .local => "local",
        .global => "global",
        .inherited => "inherited",
    };
}

fn card(w: *std.Io.Writer, label: []const u8, value: anytype, hot: bool, warn: bool) !void {
    try w.writeAll("<div class=\"card");
    if (hot) try w.writeAll(" hot");
    if (warn) try w.writeAll(" warn");
    try w.writeAll("\"><b>");
    try w.print("{d}", .{value});
    try w.writeAll("</b><span>");
    try htmlEscape(w, label);
    try w.writeAll("</span></div>\n");
}

fn writeGraphBlock(w: *std.Io.Writer, io: Io, svg_path: []const u8, rendered: bool) !void {
    if (!rendered) {
        try w.writeAll("<p class=\"muted\">Graphviz did not render this graph. DOT was written next to the report.</p>\n");
        return;
    }
    try w.writeAll("<div class=\"graph-shell\"><div class=\"graph-tools\">\n");
    try w.writeAll("<button type=\"button\" data-graph-action=\"out\" title=\"Zoom out\">&minus;</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-action=\"in\" title=\"Zoom in\">+</button>\n");
    try w.writeAll("<button type=\"button\" data-graph-action=\"reset\" title=\"Reset zoom\">Reset</button>\n");
    try w.writeAll("<span class=\"hint\">Wheel to zoom · drag to pan · double-click a node or cluster to focus</span>\n");
    try w.writeAll("</div><div class=\"graph\" data-graph>");
    try embedSvg(w, io, svg_path);
    try w.writeAll("</div></div>\n");
}

fn embedSvg(w: *std.Io.Writer, io: Io, path: []const u8) !void {
    const data = Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        std.heap.page_allocator,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    ) catch return;
    defer std.heap.page_allocator.free(data);
    var start: usize = 0;
    if (std.mem.indexOf(u8, data, "<svg")) |idx| start = idx;
    const end = std.mem.lastIndexOf(u8, data, "</svg>") orelse return;
    try w.writeAll(data[start .. end + 6]);
}
