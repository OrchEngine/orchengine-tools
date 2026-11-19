const std = @import("std");
const model = @import("model.zig");

const Model = model.Model;
const Gpa = model.Gpa;
const no_fn = model.no_fn;

pub fn run(model_ptr: *Model) !void {
    try buildIndices(model_ptr);
    if (model_ptr.config.track_capabilities) computeCapabilities(model_ptr);
    try findCycles(model_ptr);
    try addImportCycleFindings(model_ptr);
    model_ptr.applySuppressions();
    computeDebt(model_ptr);
    try computeChains(model_ptr);
}

fn buildIndices(model_ptr: *Model) !void {
    const gpa = model_ptr.gpa;

    // Per-file function name index. Duplicate names are marked ambiguous.
    for (model_ptr.files.items) |*file| {
        for (file.fns.items) |fn_idx| {
            const name = model_ptr.fns.items[fn_idx].name;
            const gop = try file.fn_names.getOrPut(gpa, name);
            if (!gop.found_existing) {
                gop.value_ptr.* = fn_idx;
            } else if (gop.value_ptr.* != no_fn) {
                gop.value_ptr.* = no_fn;
            }
        }
    }

    // Globally unique function names.
    for (model_ptr.fns.items, 0..) |f, i| {
        const gop = try model_ptr.global_fn.getOrPut(gpa, f.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(i);
        } else if (gop.value_ptr.* != no_fn) {
            gop.value_ptr.* = no_fn;
            model_ptr.ambiguous_names += 1;
        }
    }

    // Resolve imports and aliases.
    for (model_ptr.files.items, 0..) |*file, file_idx| {
        for (file.imports.items) |*imp| {
            imp.resolved = model_ptr.resolveImport(@intCast(file_idx), imp.raw);
            if (imp.resolved) |target| {
                if (imp.alias) |alias| {
                    try file.aliases.put(gpa, alias, target);
                }
            } else if (!Model.isExternalImport(imp.raw) and !file.generated) {
                if (model_ptr.resolveImportPath(@intCast(file_idx), imp.raw)) |target_path| {
                    if (model_ptr.excluded_by_path.contains(target_path)) {
                        imp.excluded = true;
                        continue;
                    }
                }
                try model_ptr.module_imports.append(gpa, .{
                    .raw = imp.raw,
                    .file = @intCast(file_idx),
                    .line = imp.line,
                });
            }
        }
    }

    // Resolve calls.
    for (model_ptr.calls.items, 0..) |*call, call_idx| {
        const caller = call.caller orelse continue;
        const caller_info = model_ptr.fns.items[caller];
        const caller_file = caller_info.file;
        const file = &model_ptr.files.items[caller_file];
        var found: ?u32 = null;
        var confidence: model.Confidence = .unresolved;

        if (call.receiver) |recv| {
            if (isExternalReceiver(recv)) {
                call.confidence = .external;
                model_ptr.external_calls += 1;
                continue;
            }

            if (std.mem.eql(u8, recv, "self")) {
                if (caller_info.parent) |parent| {
                    if (findMethod(model_ptr, caller_file, parent, call.name)) |fn_idx| {
                        found = fn_idx;
                        confidence = .method;
                    }
                }
            } else if (file.aliases.get(recv)) |target_file| {
                if (model_ptr.files.items[target_file].fn_names.get(call.name)) |fn_idx| {
                    if (fn_idx != no_fn) {
                        found = fn_idx;
                        confidence = .alias;
                    }
                }
            } else if (findMethod(model_ptr, caller_file, recv, call.name)) |fn_idx| {
                found = fn_idx;
                confidence = .method;
            }
        } else {
            if (file.fn_names.get(call.name)) |fn_idx| {
                if (fn_idx != no_fn) {
                    found = fn_idx;
                    confidence = .same_file;
                }
            } else if (model_ptr.global_fn.get(call.name)) |fn_idx| {
                if (fn_idx != no_fn) {
                    const target_file = model_ptr.fns.items[fn_idx].file;
                    if (importsFile(model_ptr, caller_file, target_file)) {
                        found = fn_idx;
                        confidence = .global;
                    }
                }
            }
        }

        if (found) |callee| {
            call.resolved = callee;
            call.confidence = confidence;
            model_ptr.resolved_calls += 1;
            try model_ptr.fns.items[callee].callers.append(gpa, caller);
            try model_ptr.fns.items[caller].call_sites.append(gpa, @intCast(call_idx));
        } else {
            model_ptr.unresolved_calls += 1;
        }
    }
}

fn isExternalReceiver(recv: []const u8) bool {
    if (std.mem.eql(u8, recv, "std") or std.mem.eql(u8, recv, "builtin")) return true;
    if (std.mem.startsWith(u8, recv, "std.")) return true;
    if (std.mem.startsWith(u8, recv, "@")) return true;
    return false;
}

fn importsFile(model_ptr: *Model, from: u32, target: u32) bool {
    for (model_ptr.files.items[from].imports.items) |imp| {
        if (imp.resolved == target) return true;
    }
    return false;
}

fn findMethod(model_ptr: *Model, file_idx: u32, type_name: []const u8, fn_name: []const u8) ?u32 {
    var found: ?u32 = null;
    for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
        const f = model_ptr.fns.items[fn_idx];
        const parent = f.parent orelse continue;
        if (!std.mem.eql(u8, parent, type_name)) continue;
        if (!std.mem.eql(u8, f.name, fn_name)) continue;
        if (found != null) return null;
        found = fn_idx;
    }
    return found;
}

// ---------------------------------------------------------------------------
// Capabilities (allocator / Io)

fn computeCapabilities(model_ptr: *Model) void {
    const gpa = model_ptr.gpa;
    const nfns = model_ptr.fns.items.len;
    if (nfns == 0) return;

    const in_queue = gpa.alloc(bool, nfns) catch return;
    defer gpa.free(in_queue);
    @memset(in_queue, false);

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(gpa);

    for (model_ptr.fns.items) |*f| {
        f.needs_allocator = f.sig_allocator or f.direct_allocator;
        f.needs_io = f.sig_io or f.direct_io or (model_ptr.config.debug_io and f.debug_io);
        if (model_ptr.config.debug_io and f.debug_io and f.io_source == .none) f.io_source = .local;
    }

    for (model_ptr.fns.items, 0..) |f, i| {
        if (f.needs_allocator or f.needs_io) {
            in_queue[i] = true;
            queue.append(gpa, @intCast(i)) catch return;
        }
    }

    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const callee_idx = queue.items[index];
        in_queue[callee_idx] = false;
        const callee = model_ptr.fns.items[callee_idx];

        for (callee.callers.items) |caller_idx| {
            var changed = false;
            const caller = &model_ptr.fns.items[caller_idx];

            if (callee.needs_allocator and !caller.needs_allocator) {
                caller.needs_allocator = true;
                if (!caller.sig_allocator and !caller.direct_allocator) {
                    caller.inherited_allocator = true;
                    if (caller.alloc_source == .none) {
                        caller.alloc_source = if (caller.parent_allocator) .field else .inherited;
                    }
                }
                changed = true;
            }
            if (callee.needs_io and !caller.needs_io) {
                caller.needs_io = true;
                if (!caller.sig_io and !caller.direct_io) {
                    caller.inherited_io = true;
                    if (caller.io_source == .none) {
                        caller.io_source = if (caller.parent_io) .field else .inherited;
                    }
                }
                changed = true;
            }

            if (changed and !in_queue[caller_idx]) {
                in_queue[caller_idx] = true;
                queue.append(gpa, caller_idx) catch return;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Cycles (Tarjan strongly connected components)

const ImportTarjan = struct {
    model: *Model,
    index: []i32,
    low: []u32,
    on_stack: []bool,
    stack: std.ArrayList(u32) = .empty,
    next_index: u32 = 0,
    cycles: *std.ArrayList(model.Cycle),
};

fn importStrongconnect(t: *ImportTarjan, v: u32) !void {
    const gpa = t.model.gpa;
    t.index[v] = @intCast(t.next_index);
    t.low[v] = t.next_index;
    t.next_index += 1;
    try t.stack.append(gpa, v);
    t.on_stack[v] = true;

    for (t.model.files.items[v].imports.items) |imp| {
        const w = imp.resolved orelse continue;
        if (t.index[w] < 0) {
            try importStrongconnect(t, w);
            t.low[v] = @min(t.low[v], t.low[w]);
        } else if (t.on_stack[w]) {
            t.low[v] = @min(t.low[v], @as(u32, @intCast(t.index[w])));
        }
    }

    if (t.low[v] == @as(u32, @intCast(t.index[v]))) {
        var component: std.ArrayList(u32) = .empty;
        defer component.deinit(gpa);
        while (true) {
            const w = t.stack.pop().?;
            t.on_stack[w] = false;
            try component.append(gpa, w);
            if (w == v) break;
        }

        var self_loop = false;
        if (component.items.len == 1) {
            const only = component.items[0];
            for (t.model.files.items[only].imports.items) |imp| {
                if (imp.resolved == only) {
                    self_loop = true;
                    break;
                }
            }
        }
        if (component.items.len > 1 or self_loop) {
            const nodes = try gpa.dupe(u32, component.items);
            const cycle_id: u32 = @intCast(t.cycles.items.len);
            try t.cycles.append(gpa, .{ .nodes = nodes });
            for (nodes) |file_idx| {
                t.model.files.items[file_idx].in_import_cycle = true;
                t.model.files.items[file_idx].cycle_id = cycle_id;
            }
        }
    }
}

const CallTarjan = struct {
    model: *Model,
    index: []i32,
    low: []u32,
    on_stack: []bool,
    stack: std.ArrayList(u32) = .empty,
    next_index: u32 = 0,
    cycles: *std.ArrayList(model.Cycle),
};

fn callStrongconnect(t: *CallTarjan, v: u32) !void {
    const gpa = t.model.gpa;
    t.index[v] = @intCast(t.next_index);
    t.low[v] = t.next_index;
    t.next_index += 1;
    try t.stack.append(gpa, v);
    t.on_stack[v] = true;

    for (t.model.fns.items[v].call_sites.items) |call_idx| {
        const w = t.model.calls.items[call_idx].resolved orelse continue;
        if (t.index[w] < 0) {
            try callStrongconnect(t, w);
            t.low[v] = @min(t.low[v], t.low[w]);
        } else if (t.on_stack[w]) {
            t.low[v] = @min(t.low[v], @as(u32, @intCast(t.index[w])));
        }
    }

    if (t.low[v] == @as(u32, @intCast(t.index[v]))) {
        var component: std.ArrayList(u32) = .empty;
        defer component.deinit(gpa);
        while (true) {
            const w = t.stack.pop().?;
            t.on_stack[w] = false;
            try component.append(gpa, w);
            if (w == v) break;
        }

        var self_loop = false;
        if (component.items.len == 1) {
            const only = component.items[0];
            for (t.model.fns.items[only].call_sites.items) |call_idx| {
                if (t.model.calls.items[call_idx].resolved == only) {
                    self_loop = true;
                    break;
                }
            }
        }
        if (component.items.len > 1 or self_loop) {
            const nodes = try gpa.dupe(u32, component.items);
            const cycle_id: u32 = @intCast(t.cycles.items.len);
            try t.cycles.append(gpa, .{ .nodes = nodes });
            for (nodes) |fn_idx| {
                t.model.fns.items[fn_idx].in_call_cycle = true;
                t.model.fns.items[fn_idx].cycle_id = cycle_id;
            }
        }
    }
}

fn findCycles(model_ptr: *Model) !void {
    const gpa = model_ptr.gpa;

    const nfiles = model_ptr.files.items.len;
    const iindex = try gpa.alloc(i32, nfiles);
    const ilow = try gpa.alloc(u32, nfiles);
    const ion = try gpa.alloc(bool, nfiles);
    @memset(iindex, -1);
    @memset(ilow, 0);
    @memset(ion, false);
    var it = ImportTarjan{
        .model = model_ptr,
        .index = iindex,
        .low = ilow,
        .on_stack = ion,
        .cycles = &model_ptr.import_cycles,
    };
    for (0..nfiles) |v| {
        if (it.index[v] < 0) try importStrongconnect(&it, @intCast(v));
    }

    const nfns = model_ptr.fns.items.len;
    const cindex = try gpa.alloc(i32, nfns);
    const clow = try gpa.alloc(u32, nfns);
    const con = try gpa.alloc(bool, nfns);
    @memset(cindex, -1);
    @memset(clow, 0);
    @memset(con, false);
    var ct = CallTarjan{
        .model = model_ptr,
        .index = cindex,
        .low = clow,
        .on_stack = con,
        .cycles = &model_ptr.call_cycles,
    };
    for (0..nfns) |v| {
        if (ct.index[v] < 0) try callStrongconnect(&ct, @intCast(v));
    }

    for (model_ptr.call_cycles.items) |cycle| {
        if (cycle.nodes.len > 1) model_ptr.mutual_call_cycles += 1;
    }
}

// ---------------------------------------------------------------------------
// Project findings

fn addImportCycleFindings(model_ptr: *Model) !void {
    const gpa = model_ptr.gpa;
    const severity = model_ptr.projectSeverity("import-cycle");
    for (model_ptr.import_cycles.items) |cycle| {
        if (cycle.nodes.len == 0 or cycleHasGenerated(model_ptr, cycle)) continue;
        try model_ptr.findings.append(gpa, .{
            .rule_id = "import-cycle",
            .severity = severity,
            .message = try cycleMessage(model_ptr, cycle),
            .path = model_ptr.fileLabel(cycle.nodes[0]),
            .line = cycleEdgeLine(model_ptr, cycle),
            .source = .project,
            .weight = model_ptr.findingWeight("import-cycle", severity),
            .key = try cycleKey(model_ptr, cycle),
        });
    }
}

fn cycleHasGenerated(model_ptr: *Model, cycle: model.Cycle) bool {
    for (cycle.nodes) |file_idx| {
        if (model_ptr.files.items[file_idx].generated) return true;
    }
    return false;
}

fn cycleKey(model_ptr: *Model, cycle: model.Cycle) ![]const u8 {
    const gpa = model_ptr.gpa;
    const labels = try gpa.alloc([]const u8, cycle.nodes.len);
    for (cycle.nodes, 0..) |file_idx, i| labels[i] = model_ptr.fileLabel(file_idx);
    std.mem.sort([]const u8, labels, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);

    var out: std.ArrayList(u8) = .empty;
    for (labels, 0..) |label, i| {
        if (i != 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, label);
    }
    return out.toOwnedSlice(gpa);
}

fn cycleMessage(model_ptr: *Model, cycle: model.Cycle) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(model_ptr.gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("import cycle: ");
    for (cycle.nodes, 0..) |file_idx, i| {
        if (i != 0) try w.writeAll(" -> ");
        try w.writeAll(model_ptr.fileLabel(file_idx));
    }
    if (cycle.nodes.len > 0) {
        try w.writeAll(" -> ");
        try w.writeAll(model_ptr.fileLabel(cycle.nodes[0]));
    }
    return model_ptr.gpa.dupe(u8, aw.written());
}

fn cycleEdgeLine(model_ptr: *Model, cycle: model.Cycle) u32 {
    if (cycle.nodes.len == 0) return 0;
    for (cycle.nodes, 0..) |from, i| {
        const to = cycle.nodes[(i + 1) % cycle.nodes.len];
        for (model_ptr.files.items[from].imports.items) |imp| {
            if (imp.resolved == to) return imp.line;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Debt

fn computeDebt(model_ptr: *Model) void {
    var fn_total: u32 = 0;
    var file_total: u32 = 0;
    var total: u32 = 0;
    var zlint_total: u32 = 0;
    var project_total: u32 = 0;

    for (model_ptr.fns.items) |*f| f.debt_min = 0;
    for (model_ptr.files.items) |*file| file.debt_min = 0;

    for (model_ptr.findings.items) |finding| {
        if (finding.suppressed) continue;
        total += finding.weight;
        switch (finding.source) {
            .zlint => zlint_total += finding.weight,
            .project => project_total += finding.weight,
        }

        const file_idx = model_ptr.fileIndexByPath(finding.path) orelse continue;
        model_ptr.files.items[file_idx].debt_min += finding.weight;
        file_total += finding.weight;

        if (finding.line == 0) continue;
        for (model_ptr.files.items[file_idx].fns.items) |fn_idx| {
            const f = &model_ptr.fns.items[fn_idx];
            if (finding.line >= f.line and finding.line <= f.end_line) {
                f.debt_min += finding.weight;
                fn_total += finding.weight;
                break;
            }
        }
    }

    model_ptr.fn_debt = fn_total;
    model_ptr.file_debt = file_total;
    model_ptr.structural_debt = total - fn_total;
    model_ptr.debug_debt = 0;
    model_ptr.cycle_debt = 0;
    model_ptr.zlint_debt = zlint_total;
    model_ptr.project_debt = project_total;
    model_ptr.total_debt = total;
}

// ---------------------------------------------------------------------------
// Call chains

fn longestFrom(
    model_ptr: *Model,
    fn_idx: u32,
    visited: []bool,
    path: *std.ArrayList(u32),
    best: *std.ArrayList(u32),
    depth: u32,
    steps: *u32,
) !void {
    if (depth > 32) return;
    steps.* += 1;
    if (steps.* > 200_000) return;
    visited[fn_idx] = true;
    try path.append(model_ptr.gpa, fn_idx);
    if (path.items.len > best.items.len) {
        best.clearRetainingCapacity();
        try best.appendSlice(model_ptr.gpa, path.items);
    }

    for (model_ptr.fns.items[fn_idx].call_sites.items) |call_idx| {
        const callee = model_ptr.calls.items[call_idx].resolved orelse continue;
        if (visited[callee]) continue;
        try longestFrom(model_ptr, callee, visited, path, best, depth + 1, steps);
    }

    _ = path.pop();
    visited[fn_idx] = false;
}

fn computeChains(model_ptr: *Model) !void {
    const gpa = model_ptr.gpa;
    const nfns = model_ptr.fns.items.len;
    if (nfns == 0) return;

    var roots: std.ArrayList(u32) = .empty;
    defer roots.deinit(gpa);

    for (model_ptr.fns.items, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, "main")) try roots.append(gpa, @intCast(i));
    }

    if (roots.items.len == 0) {
        for (model_ptr.fns.items, 0..) |f, i| {
            if (roots.items.len >= 8) break;
            if (!f.is_pub) continue;
            if (f.callers.items.len != 0) continue;
            try roots.append(gpa, @intCast(i));
        }
    }

    const visited = try gpa.alloc(bool, nfns);
    var path: std.ArrayList(u32) = .empty;
    defer path.deinit(gpa);

    for (roots.items) |root| {
        @memset(visited, false);
        var best: std.ArrayList(u32) = .empty;
        defer best.deinit(gpa);
        path.clearRetainingCapacity();
        var steps: u32 = 0;
        try longestFrom(model_ptr, root, visited, &path, &best, 0, &steps);
        if (best.items.len > 1) {
            try model_ptr.chains.append(gpa, .{
                .root = root,
                .nodes = try gpa.dupe(u32, best.items),
            });
        }
    }

    std.mem.sort(model.Chain, model_ptr.chains.items, {}, struct {
        fn less(_: void, a: model.Chain, b: model.Chain) bool {
            return a.nodes.len > b.nodes.len;
        }
    }.less);
}

test "capabilities propagate to callers" {
    const alloc = std.testing.allocator;
    var m = Model{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
    try m.fns.append(alloc, .{
        .name = "callee",
        .file = 0,
        .line = 1,
        .end_line = 1,
        .start = 0,
        .end = 1,
        .params = 1,
        .complexity = 1,
        .nesting = 0,
        .loc = 1,
        .is_pub = false,
        .has_doc = true,
        .sig_allocator = true,
        .alloc_source = .param,
    });
    try m.fns.append(alloc, .{
        .name = "caller",
        .file = 0,
        .line = 2,
        .end_line = 2,
        .start = 2,
        .end = 3,
        .params = 0,
        .complexity = 1,
        .nesting = 0,
        .loc = 1,
        .is_pub = false,
        .has_doc = true,
        .parent_allocator = true,
    });
    try m.fns.items[1].callers.append(alloc, 0);
    computeCapabilities(&m);

    try std.testing.expect(m.fns.items[0].needs_allocator);
    try std.testing.expect(m.fns.items[1].needs_allocator);
    try std.testing.expect(m.fns.items[1].inherited_allocator);
    try std.testing.expectEqual(model.CapSource.field, m.fns.items[1].alloc_source);
    try std.testing.expect(!m.fns.items[1].needs_io);
}

fn testModel(alloc: std.mem.Allocator) !Model {
    var m = Model{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
    _ = try m.addFile("a.zig", "");
    try m.fns.append(alloc, .{
        .name = "f",
        .file = 0,
        .line = 10,
        .end_line = 20,
        .start = 0,
        .end = 1,
        .params = 1,
        .complexity = 1,
        .nesting = 0,
        .loc = 10,
        .is_pub = false,
        .has_doc = true,
    });
    try m.files.items[0].fns.append(alloc, 0);
    return m;
}

test "findings drive debt" {
    const alloc = std.testing.allocator;
    var m = try testModel(alloc);
    try m.findings.append(alloc, .{
        .rule_id = "test-rule",
        .severity = .@"error",
        .message = "bad",
        .path = "a.zig",
        .line = 12,
        .source = .zlint,
        .weight = 10,
    });
    computeDebt(&m);

    try std.testing.expectEqual(@as(u32, 10), m.total_debt);
    try std.testing.expectEqual(@as(u32, 10), m.zlint_debt);
    try std.testing.expectEqual(@as(u32, 10), m.fn_debt);
    try std.testing.expectEqual(@as(u32, 10), m.fns.items[0].debt_min);
    try std.testing.expectEqual(@as(u32, 0), m.structural_debt);
}

test "suppressed findings do not drive debt" {
    const alloc = std.testing.allocator;
    var m = try testModel(alloc);
    try m.findings.append(alloc, .{
        .rule_id = "test-rule",
        .severity = .@"error",
        .message = "bad",
        .path = "a.zig",
        .line = 12,
        .source = .zlint,
        .weight = 10,
        .suppressed = true,
        .suppression_reason = "accepted",
    });
    computeDebt(&m);

    try std.testing.expectEqual(@as(u32, 0), m.total_debt);
    try std.testing.expectEqual(@as(u32, 0), m.fns.items[0].debt_min);
}

test "findings outside functions are structural" {
    const alloc = std.testing.allocator;
    var m = try testModel(alloc);
    try m.findings.append(alloc, .{
        .rule_id = "test-rule",
        .severity = .warning,
        .message = "bad",
        .path = "a.zig",
        .line = 30,
        .source = .zlint,
        .weight = 3,
    });
    computeDebt(&m);

    try std.testing.expectEqual(@as(u32, 3), m.total_debt);
    try std.testing.expectEqual(@as(u32, 0), m.fn_debt);
    try std.testing.expectEqual(@as(u32, 3), m.structural_debt);
}

test "import cycle finding and suppression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m = Model{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
    const a = try m.addFile("a.zig", "");
    const b = try m.addFile("b.zig", "");
    try m.files.items[a].imports.append(alloc, .{ .raw = "b.zig", .line = 3, .resolved = b });
    try m.files.items[b].imports.append(alloc, .{ .raw = "a.zig", .line = 4, .resolved = a });

    try findCycles(&m);
    try addImportCycleFindings(&m);

    try std.testing.expectEqual(@as(usize, 1), m.findings.items.len);
    const finding = m.findings.items[0];
    try std.testing.expectEqualStrings("import-cycle", finding.rule_id);
    try std.testing.expectEqual(model.Severity.warning, finding.severity);
    try std.testing.expectEqualStrings("a.zig,b.zig", finding.key.?);
    try std.testing.expect(finding.line > 0);

    try m.config.suppressions.append(alloc, .{
        .rule_id = "import-cycle",
        .key = "a.zig,b.zig",
        .reason = "legacy",
    });
    m.applySuppressions();
    computeDebt(&m);

    try std.testing.expect(m.findings.items[0].suppressed);
    try std.testing.expectEqual(@as(u32, 0), m.total_debt);
}
