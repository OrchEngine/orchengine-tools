const std = @import("std");
const Ast = std.zig.Ast;
const Io = std.Io;
const model = @import("model.zig");

const Model = model.Model;
const Gpa = model.Gpa;

const Ctrl = struct {
    node: Ast.Node.Index,
    start: u32,
    end: u32,
    depth: u32 = 0,
    is_if: bool = false,
};

fn isControlTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .if_simple, .@"if", .while_simple, .while_cont, .@"while", .for_simple, .@"for", .@"switch", .switch_comma, .@"catch" => true,
        else => false,
    };
}

fn lessBySize(_: void, a: Ctrl, b: Ctrl) bool {
    return (a.end - a.start) < (b.end - b.start);
}

fn isElseIf(ast: *const Ast, parent: Ast.Node.Index, child: Ast.Node.Index) bool {
    const info = ast.fullIf(parent) orelse return false;
    const else_expr = info.ast.else_expr.unwrap() orelse return false;
    return else_expr == child;
}

/// Maximum control-flow nesting inside [start, end], ignoring struct/array
/// literal braces. Else-if chains count as the same level.
fn nestingDepth(ast: *const Ast, start: u32, end: u32) u32 {
    var nested_fns: std.ArrayList(struct { start: u32, end: u32 }) = .empty;
    const gpa = std.heap.page_allocator;
    defer nested_fns.deinit(gpa);

    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const s = model.spanStart(ast, node);
        const e = model.spanEnd(ast, node);
        if (s > start and e < end) {
            nested_fns.append(gpa, .{ .start = s, .end = e }) catch {};
        }
    }

    var list: std.ArrayList(Ctrl) = .empty;
    defer list.deinit(gpa);

    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (!isControlTag(tag)) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const s = model.spanStart(ast, node);
        const e = model.spanEnd(ast, node);
        if (s < start or e > end) continue;
        var skip = false;
        for (nested_fns.items) |nf| {
            if (s >= nf.start and e <= nf.end) {
                skip = true;
                break;
            }
        }
        if (skip) continue;
        list.append(gpa, .{
            .node = node,
            .start = s,
            .end = e,
            .is_if = tag == .@"if" or tag == .if_simple,
        }) catch {};
    }

    std.mem.sort(Ctrl, list.items, {}, lessBySize);
    var max: u32 = 0;
    for (list.items, 0..) |*item, i| {
        var best_parent: ?*const Ctrl = null;
        for (list.items[0..i]) |*candidate| {
            if (candidate.start <= item.start and candidate.end >= item.end) {
                if (best_parent == null or candidate.depth > best_parent.?.depth) {
                    best_parent = candidate;
                }
            }
        }
        if (best_parent) |parent| {
            if (item.is_if and parent.is_if and isElseIf(ast, parent.node, item.node)) {
                item.depth = parent.depth;
            } else {
                item.depth = parent.depth + 1;
            }
        } else {
            item.depth = 1;
        }
        if (item.depth > max) max = item.depth;
    }
    return max;
}

fn isContainerTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => true,
        else => false,
    };
}

const Container = struct {
    node: Ast.Node.Index,
    name: []const u8,
    start: u32,
    end: u32,
    type_id: u32,
    has_allocator_field: bool = false,
    has_io_field: bool = false,
};

fn containerFor(containers: []Container, start: u32, end: u32) ?*Container {
    var best: ?*Container = null;
    for (containers) |*c| {
        if (start >= c.start and end <= c.end) {
            if (best == null or (c.end - c.start) < (best.?.end - best.?.start)) best = c;
        }
    }
    return best;
}

fn collectContainers(model_ptr: *Model, ast: *const Ast, source: []const u8, file_idx: u32) ![]Container {
    const gpa = model_ptr.gpa;
    var names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty;
    defer names.deinit(gpa);

    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const vd = ast.fullVarDecl(node) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        if (!isContainerTag(ast.nodeTag(init))) continue;
        const name = ast.tokenSlice(vd.ast.mut_token + 1);
        try names.put(gpa, @backingInt(init), name);
    }

    var list: std.ArrayList(Container) = .empty;
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (!isContainerTag(tag)) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const name = names.get(@backingInt(node)) orelse continue;
        const start = model.spanStart(ast, node);
        const type_id: u32 = @intCast(model_ptr.types.items.len);
        try model_ptr.types.append(gpa, .{
            .name = name,
            .file = file_idx,
            .line = Model.lineOf(source, start),
        });
        try model_ptr.files.items[file_idx].type_names.put(gpa, name, type_id);
        try list.append(gpa, .{
            .node = node,
            .name = name,
            .start = start,
            .end = model.spanEnd(ast, node),
            .type_id = type_id,
        });
    }

    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .container_field_init, .container_field_align, .container_field => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const field = ast.fullContainerField(node) orelse continue;
        const type_expr = field.ast.type_expr.unwrap() orelse continue;
        const field_type = model.tokenTextRange(ast, type_expr, source);
        const container = containerFor(list.items, model.spanStart(ast, node), model.spanEnd(ast, node)) orelse continue;
        if (looksAllocator(field_type)) container.has_allocator_field = true;
        if (looksIoType(field_type)) container.has_io_field = true;

        const field_id: u32 = @intCast(model_ptr.fields.items.len);
        try model_ptr.fields.append(gpa, .{
            .name = ast.tokenSlice(ast.nodeMainToken(node)),
            .type_text = field_type,
            .container = container.name,
            .file = file_idx,
            .line = Model.lineOf(source, model.spanStart(ast, node)),
            .is_pointer = std.mem.indexOfScalar(u8, field_type, '*') != null,
            .is_slice = std.mem.startsWith(u8, std.mem.trimStart(u8, field_type, " \t"), "["),
            .is_allocator = looksAllocator(field_type),
            .is_io = looksIoType(field_type),
        });
        try model_ptr.types.items[container.type_id].fields.append(gpa, field_id);
    }

    return list.toOwnedSlice(gpa);
}

fn parentOf(containers: []const Container, start: u32, end: u32) ?[]const u8 {
    var best: ?*const Container = null;
    for (containers) |*c| {
        if (start >= c.start and end <= c.end) {
            if (best == null or (c.end - c.start) < (best.?.end - best.?.start)) best = c;
        }
    }
    return if (best) |c| c.name else null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn defaultGeneratedMarker(text: []const u8) bool {
    if (containsIgnoreCase(text, "code generated")) return true;
    if (containsIgnoreCase(text, "@generated")) return true;
    if (containsIgnoreCase(text, "generated") and
        (containsIgnoreCase(text, "do not edit") or containsIgnoreCase(text, "automatically generated")))
        return true;
    return false;
}

fn detectGenerated(model_ptr: *Model, source: []const u8, rel_path: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    while (line_no < 20) : (line_no += 1) {
        const raw = lines.next() orelse break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "//")) break;
        const text = std.mem.trimStart(u8, line, "/! \t");
        if (defaultGeneratedMarker(text)) return "generated header";
        for (model_ptr.config.generated_markers.items) |marker| {
            if (containsIgnoreCase(text, marker)) return "configured generated marker";
        }
    }

    for (model_ptr.config.generated_paths.items) |pattern| {
        if (model.pathMatches(pattern, rel_path)) return "configured generated path";
    }
    return null;
}

fn isExcluded(model_ptr: *Model, rel_path: []const u8) bool {
    for (model_ptr.config.exclude.items) |pattern| {
        if (model.pathMatches(pattern, rel_path)) return true;
    }
    return false;
}

fn listFile(model_ptr: *Model, kind: []const u8, rel_path: []const u8, reason: []const u8) void {
    if (!model_ptr.list_files) return;
    if (reason.len == 0) {
        std.debug.print("{s:<12}{s}\n", .{ kind, rel_path });
    } else {
        std.debug.print("{s:<12}{s}  ({s})\n", .{ kind, rel_path, reason });
    }
}

fn looksAllocator(text: []const u8) bool {
    if (containsIgnoreCase(text, "allocator")) return true;
    if (std.mem.eql(u8, text, "gpa") or std.mem.eql(u8, text, "arena")) return true;
    if (std.mem.indexOf(u8, text, ".gpa") != null) return true;
    if (std.mem.indexOf(u8, text, ".arena") != null) return true;
    if (containsIgnoreCase(text, "std.heap.")) return true;
    return false;
}

fn looksIo(text: []const u8) bool {
    if (std.mem.eql(u8, text, "io")) return true;
    if (std.mem.startsWith(u8, text, "io.")) return true;
    if (std.mem.startsWith(u8, text, "std.Io")) return true;
    if (containsIgnoreCase(text, "std.Io.")) return true;
    if (std.mem.eql(u8, text, "writer") or std.mem.startsWith(u8, text, "writer.")) return true;
    if (std.mem.eql(u8, text, "reader") or std.mem.startsWith(u8, text, "reader.")) return true;
    if (std.mem.eql(u8, text, "self.io") or std.mem.eql(u8, text, "self.writer") or std.mem.eql(u8, text, "self.reader")) return true;
    if (std.mem.indexOf(u8, text, ".io") != null) return true;
    if (std.mem.indexOf(u8, text, ".writer") != null) return true;
    if (std.mem.indexOf(u8, text, ".reader") != null) return true;
    return false;
}

/// Type-shaped Io detection for signatures and fields. This is intentionally
/// separate from expression detection so a variable named `request` is not
/// treated as an Io method receiver.
fn looksIoType(text: []const u8) bool {
    if (looksIo(text)) return true;
    const io_types = [_][]const u8{
        "Request", "Response", "Writer", "Reader", "Stream", "Socket", "Connection", "Server", "Client",
    };
    for (io_types) |name| {
        if (containsIgnoreCase(text, name)) return true;
    }
    return false;
}

fn isAllocatorMethod(name: []const u8) bool {
    const methods = [_][]const u8{
        "alloc", "allocWithOptions", "allocSentinel", "allocPrint", "dupe",         "dupeZ",
        "free",  "realloc",          "create",        "destroy",    "toOwnedSlice",
    };
    for (methods) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

fn isIoMethodName(name: []const u8) bool {
    const methods = [_][]const u8{
        "print",     "write",      "writeAll", "writeAllAlloc", "writeByte",     "writeByteNTimes",
        "writeFile", "read",       "readAll",  "readAllAlloc",  "readFileAlloc", "readUntilDelimiter",
        "openFile",  "createFile", "openDir",  "flush",         "json",          "body",
        "send",      "recv",       "listen",   "accept",        "connect",       "close",
        "spawn",     "sleep",
    };
    for (methods) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

fn isIoReceiver(text: []const u8) bool {
    if (std.mem.eql(u8, text, "io") or std.mem.eql(u8, text, "writer") or
        std.mem.eql(u8, text, "reader") or std.mem.eql(u8, text, "file") or
        std.mem.eql(u8, text, "dir") or std.mem.eql(u8, text, "res") or
        std.mem.eql(u8, text, "req") or std.mem.eql(u8, text, "response") or
        std.mem.eql(u8, text, "request") or std.mem.eql(u8, text, "stream") or
        std.mem.eql(u8, text, "conn") or std.mem.eql(u8, text, "socket") or
        std.mem.eql(u8, text, "server") or std.mem.eql(u8, text, "client"))
        return true;
    if (std.mem.indexOf(u8, text, ".writer") != null or
        std.mem.indexOf(u8, text, ".reader") != null or
        std.mem.indexOf(u8, text, ".io") != null or
        std.mem.indexOf(u8, text, ".file") != null or
        std.mem.indexOf(u8, text, ".dir") != null)
        return true;
    return false;
}

fn betterAllocSource(current: model.CapSource, candidate: model.CapSource) model.CapSource {
    if (current == .param or current == .field or current == .global or current == .local) return current;
    if (candidate == .param) return .param;
    if (current == .none) return candidate;
    return current;
}

fn betterIoSource(current: model.CapSource, candidate: model.CapSource) model.CapSource {
    if (current == .param or current == .field or current == .global or current == .local) return current;
    if (candidate == .param) return .param;
    if (current == .none) return candidate;
    return current;
}

fn markAllocatorUse(f: *model.FnInfo, expr: []const u8) void {
    f.direct_allocator = true;
    var source: model.CapSource = .local;
    if (std.mem.indexOf(u8, expr, ".allocator") != null or
        std.mem.indexOf(u8, expr, ".arena") != null or
        std.mem.indexOf(u8, expr, ".gpa") != null or
        std.mem.startsWith(u8, expr, "self.") or
        std.mem.startsWith(u8, expr, "this."))
    {
        source = .field;
    } else if (containsIgnoreCase(expr, "std.heap.") or containsIgnoreCase(expr, "std.testing.")) {
        source = .global;
    } else if (f.sig_allocator and std.mem.indexOfScalar(u8, expr, '.') == null) {
        source = .param;
    }
    f.alloc_source = betterAllocSource(f.alloc_source, source);
}

fn markIoUse(f: *model.FnInfo, expr: []const u8) void {
    f.direct_io = true;
    var source: model.CapSource = .local;
    if (std.mem.indexOf(u8, expr, ".io") != null or
        std.mem.indexOf(u8, expr, ".writer") != null or
        std.mem.indexOf(u8, expr, ".reader") != null or
        std.mem.startsWith(u8, expr, "self.") or
        std.mem.startsWith(u8, expr, "this."))
    {
        source = .field;
    } else if (containsIgnoreCase(expr, "std.testing.")) {
        source = .global;
    } else if (f.sig_io and std.mem.indexOfScalar(u8, expr, '.') == null) {
        source = .param;
    }
    f.io_source = betterIoSource(f.io_source, source);
}

fn markCallCapabilities(
    f: *model.FnInfo,
    ast: *const Ast,
    source: []const u8,
    call: Ast.full.Call,
    callee: []const u8,
    receiver: ?[]const u8,
    name: []const u8,
) void {
    if (containsIgnoreCase(callee, "std.debug.print")) f.debug_io = true;
    if (std.mem.startsWith(u8, callee, "std.log.")) f.logging = true;
    if (containsIgnoreCase(callee, "std.heap.")) markAllocatorUse(f, callee);
    if (std.mem.startsWith(u8, callee, "std.Io")) markIoUse(f, callee);

    if (receiver) |recv| {
        if (looksAllocator(recv)) markAllocatorUse(f, recv);
        if (looksIo(recv) or (isIoMethodName(name) and isIoReceiver(recv))) markIoUse(f, recv);
    }

    var arg_has_allocator = false;
    for (call.ast.params) |param_node| {
        const text = std.mem.trim(u8, model.tokenTextRange(ast, param_node, source), " \t\r\n");
        if (text.len == 0) continue;
        if (looksAllocator(text)) {
            arg_has_allocator = true;
            markAllocatorUse(f, text);
        }
        if (looksIo(text)) markIoUse(f, text);
    }

    if (isAllocatorMethod(name)) {
        const recv_alloc = if (receiver) |recv| looksAllocator(recv) else false;
        if (recv_alloc or arg_has_allocator) {
            if (receiver) |recv| markAllocatorUse(f, recv) else markAllocatorUse(f, "");
        }
    }
}

fn isAssignTag(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .assign,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        => true,
        else => false,
    };
}

fn isCompoundAssign(tag: Ast.Node.Tag) bool {
    return tag != .assign and isAssignTag(tag);
}

fn containsWord(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |found| {
        const before_ok = found == 0 or !std.ascii.isAlphanumeric(haystack[found - 1]) and haystack[found - 1] != '_';
        const end = found + needle.len;
        const after_ok = end == haystack.len or !std.ascii.isAlphanumeric(haystack[end]) and haystack[end] != '_';
        if (before_ok and after_ok) return true;
        i = found + 1;
    }
    return false;
}

fn typeNameFromText(model_ptr: *Model, file_idx: u32, text: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = model_ptr.files.items[file_idx].type_names.iterator();
    while (it.next()) |entry| {
        if (!containsWord(text, entry.key_ptr.*)) continue;
        if (best == null or entry.key_ptr.*.len > best.?.len) best = entry.key_ptr.*;
    }
    return best;
}

fn findField(model_ptr: *Model, type_id: u32, field_name: []const u8) ?u32 {
    for (model_ptr.types.items[type_id].fields.items) |field_id| {
        if (std.mem.eql(u8, model_ptr.fields.items[field_id].name, field_name)) return field_id;
    }
    return null;
}

fn resolveBaseType(
    model_ptr: *Model,
    ast: *const Ast,
    source: []const u8,
    file_idx: u32,
    fn_idx: u32,
    locals: *const std.StringHashMapUnmanaged([]const u8),
    node: Ast.Node.Index,
    depth: u32,
) ?[]const u8 {
    if (depth > 8) return null;
    const fn_info = model_ptr.fns.items[fn_idx];
    switch (ast.nodeTag(node)) {
        .identifier => {
            const text = ast.tokenSlice(ast.nodeMainToken(node));
            if (std.mem.eql(u8, text, "self")) return fn_info.parent;
            if (locals.get(text)) |name| return name;
            if (model_ptr.files.items[file_idx].type_names.contains(text)) return text;
            return null;
        },
        .field_access => {
            const lhs = ast.nodeData(node).node_and_token[0];
            const field_tok = ast.nodeData(node).node_and_token[1];
            const parent_name = resolveBaseType(model_ptr, ast, source, file_idx, fn_idx, locals, lhs, depth + 1) orelse return null;
            const parent_type_id = model_ptr.files.items[file_idx].type_names.get(parent_name) orelse return null;
            const field_id = findField(model_ptr, parent_type_id, ast.tokenSlice(field_tok)) orelse return null;
            return typeNameFromText(model_ptr, file_idx, model_ptr.fields.items[field_id].type_text);
        },
        .unwrap_optional => {
            const lhs = ast.nodeData(node).node_and_token[0];
            return resolveBaseType(model_ptr, ast, source, file_idx, fn_idx, locals, lhs, depth + 1);
        },
        .deref => {
            const lhs = ast.nodeData(node).node;
            return resolveBaseType(model_ptr, ast, source, file_idx, fn_idx, locals, lhs, depth + 1);
        },
        .grouped_expression => {
            const lhs = ast.nodeData(node).node_and_token[0];
            return resolveBaseType(model_ptr, ast, source, file_idx, fn_idx, locals, lhs, depth + 1);
        },
        else => {
            return typeNameFromText(model_ptr, file_idx, model.tokenTextRange(ast, node, source));
        },
    }
}

fn extractFieldAccesses(model_ptr: *Model, ast: *const Ast, source: []const u8, file_idx: u32) !void {
    const gpa = model_ptr.gpa;

    for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
        const f = model_ptr.fns.items[fn_idx];

        // Find the AST declaration for this function.
        var fn_node: ?Ast.Node.Index = null;
        for (ast.nodes.items(.tag), 0..) |tag, raw| {
            if (tag != .fn_decl) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
            if (model.spanStart(ast, node) == f.start) {
                fn_node = node;
                break;
            }
        }
        const decl_node = fn_node orelse continue;

        var locals: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer locals.deinit(gpa);

        var fbuf_local: [1]Ast.Node.Index = undefined;
        const proto = ast.fullFnProto(&fbuf_local, decl_node) orelse continue;
        var param_it = proto.iterate(ast);
        while (param_it.next()) |param| {
            const name_tok = param.name_token orelse continue;
            const type_expr = param.type_expr orelse continue;
            const type_name = typeNameFromText(model_ptr, file_idx, model.tokenTextRange(ast, type_expr, source)) orelse continue;
            try locals.put(gpa, ast.tokenSlice(name_tok), type_name);
        }

        for (ast.nodes.items(.tag), 0..) |tag, raw| {
            switch (tag) {
                .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {},
                else => continue,
            }
            const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
            const start = model.spanStart(ast, node);
            if (start < f.start or start >= f.end) continue;
            const vd = ast.fullVarDecl(node) orelse continue;
            const name = ast.tokenSlice(vd.ast.mut_token + 1);
            var type_name: ?[]const u8 = null;
            if (vd.ast.type_node.unwrap()) |type_expr| {
                type_name = typeNameFromText(model_ptr, file_idx, model.tokenTextRange(ast, type_expr, source));
            } else if (vd.ast.init_node.unwrap()) |init| {
                const init_tag = ast.nodeTag(init);
                if (init_tag == .struct_init or init_tag == .struct_init_comma) {
                    var sbuf: [2]Ast.Node.Index = undefined;
                    if (ast.fullStructInit(&sbuf, init)) |si| {
                        if (si.ast.type_expr.unwrap()) |te| {
                            type_name = typeNameFromText(model_ptr, file_idx, model.tokenTextRange(ast, te, source));
                        }
                    }
                }
            }
            if (type_name) |tn| try locals.put(gpa, name, tn);
        }

        var writes: std.AutoHashMapUnmanaged(u32, model.AccessKind) = .empty;
        defer writes.deinit(gpa);

        for (ast.nodes.items(.tag), 0..) |tag, raw| {
            if (!isAssignTag(tag)) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
            const off = model.spanStart(ast, node);
            if (off < f.start or off >= f.end) continue;
            const pair = ast.nodeData(node).node_and_node;
            const lhs = pair[0];
            if (ast.nodeTag(lhs) != .field_access) continue;
            const kind: model.AccessKind = if (isCompoundAssign(tag)) .read_write else .write;
            try writes.put(gpa, @backingInt(lhs), kind);
        }

        for (ast.nodes.items(.tag), 0..) |tag, raw| {
            if (tag != .field_access) continue;
            const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
            const off = model.spanStart(ast, node);
            if (off < f.start or off >= f.end) continue;
            const lhs = ast.nodeData(node).node_and_token[0];
            const field_tok = ast.nodeData(node).node_and_token[1];
            const base_name = resolveBaseType(model_ptr, ast, source, file_idx, fn_idx, &locals, lhs, 0) orelse continue;
            const type_id = model_ptr.files.items[file_idx].type_names.get(base_name) orelse continue;
            const field_id = findField(model_ptr, type_id, ast.tokenSlice(field_tok)) orelse continue;
            const kind = writes.get(@backingInt(node)) orelse .read;
            try model_ptr.field_accesses.append(gpa, .{
                .fn_idx = fn_idx,
                .type_id = type_id,
                .field_id = field_id,
                .line = Model.lineOf(source, off),
                .kind = kind,
            });
            const field = &model_ptr.fields.items[field_id];
            switch (kind) {
                .read => field.reads += 1,
                .write => field.writes += 1,
                .read_write => {
                    field.reads += 1;
                    field.writes += 1;
                },
            }
        }
    }
}

fn addImport(model_ptr: *Model, file_idx: u32, imp: model.Import) !void {
    const file = &model_ptr.files.items[file_idx];
    for (file.imports.items) |*existing| {
        if (std.mem.eql(u8, existing.raw, imp.raw)) {
            if (existing.alias == null and imp.alias != null) {
                existing.alias = imp.alias;
                existing.alias_start = imp.alias_start;
            }
            existing.test_refs += imp.test_refs;
            existing.prod_refs += imp.prod_refs;
            if (imp.in_test) existing.in_test = true;
            return;
        }
    }
    try file.imports.append(model_ptr.gpa, imp);
}

pub fn addPath(model_ptr: *Model, io: Io, arg: []const u8) !void {
    const stat = Io.Dir.cwd().statFile(io, arg, .{}) catch |err| {
        std.debug.print("zigdepends: skip {s}: {s}\n", .{ arg, @errorName(err) });
        return;
    };

    switch (stat.kind) {
        .file => try parseFile(model_ptr, io, arg, std.fs.path.basename(arg)),
        .directory => {
            var dir = try Io.Dir.cwd().openDir(io, arg, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(model_ptr.gpa);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                if (hasComponent(entry.path, "zig-cache")) continue;
                if (hasComponent(entry.path, ".zig-cache")) continue;
                if (hasComponent(entry.path, "zig-out")) continue;
                if (hasComponent(entry.path, "zig-pkg")) continue;
                if (hasComponent(entry.path, ".tmp")) continue;
                if (hasComponent(entry.path, "node_modules")) continue;
                if (hasComponent(entry.path, ".git")) continue;
                const display = if (std.mem.endsWith(u8, arg, "/"))
                    try std.fmt.allocPrint(model_ptr.gpa, "{s}{s}", .{ arg, entry.path })
                else
                    try std.fmt.allocPrint(model_ptr.gpa, "{s}/{s}", .{ arg, entry.path });
                try parseFile(model_ptr, io, display, entry.path);
            }
        },
        else => {},
    }
}

fn extractImports(model_ptr: *Model, ast: *const Ast, source: []const u8, file_idx: u32) !void {
    var pbuf: [2]Ast.Node.Index = undefined;

    // Top-level import aliases.
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const vd = ast.fullVarDecl(node) orelse continue;
        const init = vd.ast.init_node.unwrap() orelse continue;
        const init_tag = ast.nodeTag(init);
        if (init_tag != .builtin_call_two and init_tag != .builtin_call) continue;
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(init)), "@import")) continue;
        const params = ast.builtinCallParams(&pbuf, init) orelse continue;
        if (params.len != 1 or ast.nodeTag(params[0]) != .string_literal) continue;
        const lit = ast.tokenSlice(ast.nodeMainToken(params[0]));
        if (lit.len < 2) continue;
        try addImport(model_ptr, file_idx, .{
            .raw = lit[1 .. lit.len - 1],
            .alias = ast.tokenSlice(vd.ast.mut_token + 1),
            .line = Model.lineOf(source, ast.tokenStart(ast.nodeMainToken(init))),
            .alias_start = ast.tokenStart(vd.ast.mut_token + 1),
        });
    }

    // Imports used directly in expressions (not bound to a const).
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        switch (tag) {
            .builtin_call_two, .builtin_call_two_comma, .builtin_call, .builtin_call_comma => {},
            else => continue,
        }
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        if (!std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@import")) continue;
        const params = ast.builtinCallParams(&pbuf, node) orelse continue;
        if (params.len != 1 or ast.nodeTag(params[0]) != .string_literal) continue;
        const lit = ast.tokenSlice(ast.nodeMainToken(params[0]));
        if (lit.len < 2) continue;
        try addImport(model_ptr, file_idx, .{
            .raw = lit[1 .. lit.len - 1],
            .line = Model.lineOf(source, ast.tokenStart(ast.nodeMainToken(node))),
        });
    }
}

const TestSpan = struct {
    start: u32,
    end: u32,
};

fn collectTestSpans(gpa: Gpa, ast: *const Ast) ![]TestSpan {
    var spans: std.ArrayList(TestSpan) = .empty;
    errdefer spans.deinit(gpa);
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .test_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        try spans.append(gpa, .{
            .start = model.spanStart(ast, node),
            .end = model.spanEnd(ast, node),
        });
    }
    return spans.toOwnedSlice(gpa);
}

fn insideTestSpan(spans: []const TestSpan, offset: u32) bool {
    for (spans) |span| {
        if (offset >= span.start and offset < span.end) return true;
    }
    return false;
}

/// Classifies alias references as test or production. An alias that is only
/// referenced by test declarations is reported by the `test-only-import`
/// project rule.
fn markImportTestUsage(model_ptr: *Model, ast: *const Ast, file_idx: u32) !void {
    const file = &model_ptr.files.items[file_idx];
    if (file.imports.items.len == 0) return;

    const gpa = model_ptr.gpa;
    const spans = try collectTestSpans(gpa, ast);
    defer gpa.free(spans);

    var has_alias = false;
    for (file.imports.items) |*imp| {
        if (imp.alias == null) continue;
        has_alias = true;
        if (insideTestSpan(spans, imp.alias_start)) imp.in_test = true;
    }
    if (!has_alias) return;

    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .identifier) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const token = ast.nodeMainToken(node);
        const start = ast.tokenStart(token);
        const text = ast.tokenSlice(token);
        for (file.imports.items) |*imp| {
            const alias = imp.alias orelse continue;
            if (!std.mem.eql(u8, alias, text)) continue;
            if (insideTestSpan(spans, start)) {
                imp.test_refs += 1;
            } else {
                imp.prod_refs += 1;
            }
        }
    }
}

fn parseFile(model_ptr: *Model, io: Io, path: []const u8, rel_path: []const u8) !void {
    const gpa = model_ptr.gpa;

    if (isExcluded(model_ptr, rel_path)) {
        const reason = "excluded by config/--exclude";
        const rel_copy = try gpa.dupe(u8, rel_path);
        try model_ptr.excluded_files.append(gpa, .{ .path = rel_copy, .reason = reason });
        try model_ptr.excluded_by_path.put(gpa, path, reason);
        listFile(model_ptr, "excluded", rel_path, reason);
        return;
    }

    const source = try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    );
    const generated_reason = detectGenerated(model_ptr, source, rel_path);
    const generated = generated_reason != null;

    const file_idx = try model_ptr.addFile(path, source);
    const file = &model_ptr.files.items[file_idx];
    file.generated = generated;
    file.generated_reason = generated_reason;

    var ast = try Ast.parse(gpa, source, .{});
    file.parse_errors = @intCast(ast.errors.len);
    if (file.parse_errors > 0) {
        std.debug.print("zigdepends: {s}: {d} parse errors, analysis may be incomplete\n", .{ path, file.parse_errors });
    }

    // Imports are always extracted, even for generated files, so the
    // dependency graph keeps its boundary nodes.
    try extractImports(model_ptr, &ast, source, file_idx);
    try markImportTestUsage(model_ptr, &ast, file_idx);

    if (generated) {
        listFile(model_ptr, "generated", rel_path, generated_reason.?);
        if (!model_ptr.config.include_generated_metrics) return;
    } else {
        listFile(model_ptr, "source", rel_path, "");
    }

    var fbuf: [1]Ast.Node.Index = undefined;
    const containers = try collectContainers(model_ptr, &ast, source, file_idx);

    // Functions.
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag != .fn_decl) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const proto = ast.fullFnProto(&fbuf, node) orelse continue;
        const name_tok = proto.name_token orelse continue;
        const name = ast.tokenSlice(name_tok);
        if (name.len == 0) continue;

        const first = ast.firstToken(node);
        const last = ast.lastToken(node);
        const start = ast.tokenStart(first);
        const end = ast.tokenStart(last) + @as(u32, @intCast(ast.tokenSlice(last).len));
        const line = Model.lineOf(source, start);
        const end_line = Model.lineOf(source, end);

        var loc: u32 = 0;
        var last_line: u32 = 0;
        var complexity: u32 = 1;
        var t = first;
        while (t <= last) : (t += 1) {
            const ln = Model.lineOf(source, ast.tokenStart(t));
            if (ln != last_line) {
                loc += 1;
                last_line = ln;
            }
            switch (ast.tokenTag(t)) {
                .keyword_if, .keyword_while, .keyword_for, .keyword_switch, .keyword_catch, .keyword_orelse, .keyword_and, .keyword_or => complexity += 1,
                else => {},
            }
        }

        var sig_allocator = false;
        var sig_io = false;
        var param_it = proto.iterate(&ast);
        while (param_it.next()) |param| {
            const type_expr = param.type_expr orelse continue;
            const text = model.tokenTextRange(&ast, type_expr, source);
            if (looksAllocator(text)) sig_allocator = true;
            if (looksIoType(text)) sig_io = true;
            if (containsIgnoreCase(text, "std.process.Init")) {
                sig_allocator = true;
                sig_io = true;
            }
        }

        const nesting = nestingDepth(&ast, start, end);
        const has_doc = first > 0 and ast.tokenTag(first - 1) == .doc_comment;

        const fn_idx: u32 = @intCast(model_ptr.fns.items.len);
        const parent_container = containerFor(containers, start, end);
        try model_ptr.fns.append(gpa, .{
            .name = name,
            .parent = if (parent_container) |c| c.name else null,
            .parent_allocator = if (parent_container) |c| c.has_allocator_field else false,
            .parent_io = if (parent_container) |c| c.has_io_field else false,
            .file = file_idx,
            .line = line,
            .end_line = end_line,
            .start = start,
            .end = end,
            .params = @intCast(proto.ast.params.len),
            .complexity = complexity,
            .nesting = nesting,
            .loc = loc,
            .is_pub = proto.visib_token != null,
            .has_doc = has_doc,
            .sig_allocator = sig_allocator,
            .sig_io = sig_io,
            .alloc_source = if (sig_allocator) .param else .none,
            .io_source = if (sig_io) .param else .none,
        });
        try model_ptr.files.items[file_idx].fns.append(gpa, fn_idx);
    }

    for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
        const f = model_ptr.fns.items[fn_idx];
        const parent = f.parent orelse continue;
        const type_id = model_ptr.files.items[file_idx].type_names.get(parent) orelse continue;
        if (std.mem.eql(u8, f.name, "init") or std.mem.eql(u8, f.name, "create")) {
            model_ptr.types.items[type_id].has_init = true;
        }
        if (std.mem.eql(u8, f.name, "deinit") or std.mem.eql(u8, f.name, "destroy") or std.mem.eql(u8, f.name, "free")) {
            model_ptr.types.items[type_id].has_deinit = true;
        }
    }

    // Calls, attributed to the narrowest enclosing function.
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        const is_call = switch (tag) {
            .call, .call_comma, .call_one, .call_one_comma => true,
            else => false,
        };
        if (!is_call) continue;
        const node: Ast.Node.Index = @fromBackingInt(@intCast(raw));
        const call = ast.fullCall(&fbuf, node) orelse continue;
        const callee = std.mem.trim(u8, model.tokenTextRange(&ast, call.ast.fn_expr, source), " \t\r\n");
        if (callee.len == 0 or callee[0] == '@') continue;

        var name = callee;
        var receiver: ?[]const u8 = null;
        if (std.mem.lastIndexOfScalar(u8, callee, '.')) |dot| {
            receiver = std.mem.trim(u8, callee[0..dot], " \t\r\n");
            name = std.mem.trim(u8, callee[dot + 1 ..], " \t\r\n");
        }
        if (!isIdent(name)) continue;

        const off = ast.tokenStart(ast.nodeMainToken(node));
        var caller: ?u32 = null;
        var best: u32 = std.math.maxInt(u32);
        for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
            const f = model_ptr.fns.items[fn_idx];
            if (off >= f.start and off < f.end) {
                const span = f.end - f.start;
                if (span < best) {
                    best = span;
                    caller = fn_idx;
                }
            }
        }
        if (caller == null) continue;

        markCallCapabilities(&model_ptr.fns.items[caller.?], &ast, source, call, callee, receiver, name);
        try model_ptr.calls.append(gpa, .{
            .name = name,
            .receiver = receiver,
            .line = Model.lineOf(source, off),
            .caller = caller,
        });
    }

    // Capability cues outside call arguments (fields, ambient allocators,
    // debug logging).
    for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
        const f = &model_ptr.fns.items[fn_idx];
        const body = source[f.start..f.end];
        if (std.mem.indexOf(u8, body, "self.allocator") != null or
            std.mem.indexOf(u8, body, "this.allocator") != null or
            std.mem.indexOf(u8, body, "self.gpa") != null or
            std.mem.indexOf(u8, body, "this.gpa") != null)
        {
            markAllocatorUse(f, "self.allocator");
        }
        if (std.mem.indexOf(u8, body, "self.io") != null or
            std.mem.indexOf(u8, body, "this.io") != null)
        {
            markIoUse(f, "self.io");
        }
        if (std.mem.indexOf(u8, body, "std.heap.") != null) {
            markAllocatorUse(f, "std.heap.page_allocator");
        }
        if (std.mem.indexOf(u8, body, "std.testing.allocator") != null) {
            markAllocatorUse(f, "std.testing.allocator");
        }
        if (std.mem.indexOf(u8, body, "std.testing.io") != null) {
            markIoUse(f, "std.testing.io");
        }
        if (std.mem.indexOf(u8, body, "std.Io") != null) {
            markIoUse(f, "std.Io");
        }
        if (std.mem.indexOf(u8, body, "std.debug.print") != null or
            std.mem.indexOf(u8, body, "std.debug.info") != null) f.debug_io = true;
        if (std.mem.indexOf(u8, body, "std.log.") != null) f.logging = true;
    }

    if (model_ptr.config.track_fields) {
        try extractFieldAccesses(model_ptr, &ast, source, file_idx);
    }

    const file_mut = &model_ptr.files.items[file_idx];
    file_mut.todo_count = model.countOccurrences(source, "TODO") +
        model.countOccurrences(source, "FIXME") +
        model.countOccurrences(source, "HACK");
    file_mut.debug_output_count = model.countOccurrences(source, "std.debug.print") +
        model.countOccurrences(source, "std.debug.info") +
        model.countOccurrences(source, "std.log.debug") +
        model.countOccurrences(source, "std.log.info");
    file_mut.unreachable_count = model.countOccurrences(source, "catch unreachable");
    file_mut.swallow_count = model.countOccurrences(source, "catch {}") +
        model.countOccurrences(source, "catch{}");
    file_mut.ptr_cast_count = model.countOccurrences(source, "@ptrCast");
    file_mut.align_cast_count = model.countOccurrences(source, "@alignCast");
    file_mut.const_cast_count = model.countOccurrences(source, "@constCast");
    file_mut.from_int_count = model.countOccurrences(source, "@intFromPtr") +
        model.countOccurrences(source, "@ptrFromInt");
}

fn hasComponent(path: []const u8, name: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}

fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

test "generated detection uses headers, not filenames" {
    const alloc = std.testing.allocator;
    var m = Model{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
    defer m.config.generated_paths.deinit(alloc);
    defer m.config.generated_markers.deinit(alloc);

    try std.testing.expect(detectGenerated(&m, "// Code generated by codegen. DO NOT EDIT.\nconst x = 1;\n", "src/a.zig") != null);
    try std.testing.expect(detectGenerated(&m, "// @generated\nconst x = 1;\n", "src/a.zig") != null);
    try std.testing.expect(detectGenerated(&m, "// just a normal comment\nconst x = 1;\n", "src/generated.zig") == null);

    try m.config.generated_paths.append(alloc, "src/proto_gen/**");
    try std.testing.expect(detectGenerated(&m, "const x = 1;\n", "src/proto_gen/a.zig") != null);
}

test "allocator and io signature detection" {
    try std.testing.expect(looksAllocator("std.mem.Allocator"));
    try std.testing.expect(looksAllocator("std.heap.ArenaAllocator"));
    try std.testing.expect(looksAllocator("gpa"));
    try std.testing.expect(looksIo("std.Io"));
    try std.testing.expect(looksIo("*std.Io.Writer"));
    try std.testing.expect(looksIo("io"));
    try std.testing.expect(!looksIo("std.mem.Allocator"));
    try std.testing.expect(looksAllocator("req.arena"));
    try std.testing.expect(looksIo("req.io"));
    try std.testing.expect(looksIoType("*http.Response"));
}

test "nesting depth ignores else-if chains and struct literals" {
    const src =
        \\const S = struct { a: u32 };
        \\fn outer(a: bool, b: bool) void {
        \\    const value = S{ .a = 1 };
        \\    _ = value;
        \\    if (a) {
        \\        if (b) {
        \\            call();
        \\        }
        \\    } else if (b) {
        \\        other();
        \\    }
        \\}
    ;
    var ast = try Ast.parse(std.testing.allocator, src, .{});
    defer ast.deinit(std.testing.allocator);

    var fn_node: ?Ast.Node.Index = null;
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag == .fn_decl) {
            fn_node = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const node = fn_node orelse return error.TestExpectedFunction;
    const depth = nestingDepth(&ast, model.spanStart(&ast, node), model.spanEnd(&ast, node));
    try std.testing.expectEqual(@as(u32, 2), depth);
}

test "nesting depth counts loops and switch" {
    const src =
        \\fn f(items: []const u8) void {
        \\    for (items) |item| {
        \\        while (item == 'x') {
        \\            switch (item) {
        \\                'x' => {},
        \\                else => {},
        \\            }
        \\        }
        \\    }
        \\}
    ;
    var ast = try Ast.parse(std.testing.allocator, src, .{});
    defer ast.deinit(std.testing.allocator);

    var fn_node: ?Ast.Node.Index = null;
    for (ast.nodes.items(.tag), 0..) |tag, raw| {
        if (tag == .fn_decl) {
            fn_node = @fromBackingInt(@intCast(raw));
            break;
        }
    }
    const node = fn_node orelse return error.TestExpectedFunction;
    const depth = nestingDepth(&ast, model.spanStart(&ast, node), model.spanEnd(&ast, node));
    try std.testing.expectEqual(@as(u32, 3), depth);
}

fn extractTestSource(alloc: Gpa, source: []const u8) !Model {
    var m = Model{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
    const file_idx = try m.addFile("src/a.zig", source);
    var ast = try Ast.parse(alloc, source, .{});
    try extractImports(&m, &ast, source, file_idx);
    try markImportTestUsage(&m, &ast, file_idx);
    return m;
}

fn importByAlias(m: *const Model, file_idx: u32, alias: []const u8) !model.Import {
    for (m.files.items[file_idx].imports.items) |imp| {
        const existing = imp.alias orelse continue;
        if (std.mem.eql(u8, existing, alias)) return imp;
    }
    return error.TestExpectedImport;
}

test "marks an import used only in tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m = try extractTestSource(alloc,
        \\const std = @import("std");
        \\const helper = @import("helper.zig");
        \\const prod = @import("prod.zig");
        \\
        \\pub fn use() void {
        \\    _ = prod.value;
        \\}
        \\
        \\test "uses helper" {
        \\    _ = helper.value;
        \\}
    );

    const helper = try importByAlias(&m, 0, "helper");
    try std.testing.expectEqual(@as(u32, 1), helper.test_refs);
    try std.testing.expectEqual(@as(u32, 0), helper.prod_refs);
    try std.testing.expect(!helper.in_test);

    const prod = try importByAlias(&m, 0, "prod");
    try std.testing.expectEqual(@as(u32, 0), prod.test_refs);
    try std.testing.expectEqual(@as(u32, 1), prod.prod_refs);
}

test "marks imports declared inside a test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m = try extractTestSource(alloc,
        \\test "local helper" {
        \\    const local = @import("local.zig");
        \\    _ = local.value;
        \\}
    );

    const local = try importByAlias(&m, 0, "local");
    try std.testing.expect(local.in_test);
    try std.testing.expectEqual(@as(u32, 1), local.test_refs);
    try std.testing.expectEqual(@as(u32, 0), local.prod_refs);
}

test "direct imports have no alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m = try extractTestSource(alloc,
        \\comptime {
        \\    _ = @import("all_tests.zig");
        \\}
    );

    const imp = m.files.items[0].imports.items[0];
    try std.testing.expect(imp.alias == null);
    try std.testing.expectEqual(@as(u32, 0), imp.test_refs);
    try std.testing.expectEqual(@as(u32, 0), imp.prod_refs);
}

test "counts alias references in types and builtins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const m = try extractTestSource(alloc,
        \\const types = @import("types.zig");
        \\const helpers = @import("helpers.zig");
        \\const ignored = @import("ignored.zig");
        \\
        \\pub fn use(x: types.Value) void {
        \\    _ = x;
        \\    _ = @hasDecl(helpers, "answer");
        \\}
        \\
        \\test "ignored" {
        \\    _ = ignored;
        \\}
    );

    const types = try importByAlias(&m, 0, "types");
    try std.testing.expectEqual(@as(u32, 1), types.prod_refs);
    try std.testing.expectEqual(@as(u32, 0), types.test_refs);

    const helpers = try importByAlias(&m, 0, "helpers");
    try std.testing.expectEqual(@as(u32, 1), helpers.prod_refs);

    const ignored = try importByAlias(&m, 0, "ignored");
    try std.testing.expectEqual(@as(u32, 0), ignored.prod_refs);
    try std.testing.expectEqual(@as(u32, 1), ignored.test_refs);
}
