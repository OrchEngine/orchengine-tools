//! Dependency graph hierarchy, layout, and payload generation.
//!
//! Facades follow the repository convention: `src/<module>.zig` is the public
//! facade and `src/<module>/` contains its internals. The hierarchy nests
//! submodules below their parent module. The report renders one interactive
//! graph from the payload; Graphviz supplies the initial node positions.
const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");

const Gpa = model.Gpa;
const Model = model.Model;

pub const root_group: u32 = 0;

pub const Group = struct {
    path: []const u8,
    name: []const u8,
    parent: ?u32 = null,
    files: std.ArrayListUnmanaged(u32) = .empty,
    children: std.ArrayListUnmanaged(u32) = .empty,
    file_count: u32 = 0,
    generated_count: u32 = 0,
    cycle_files: u32 = 0,
    is_facade: bool = false,
};

pub const Hierarchy = struct {
    gpa: Gpa,
    groups: std.ArrayListUnmanaged(Group) = .empty,
    by_path: std.StringHashMapUnmanaged(u32) = .empty,
    file_groups: []u32 = &.{},
    file_paths: []const []const u8 = &.{},
    file_visible: []bool = &.{},

    pub fn deinit(self: *Hierarchy) void {
        for (self.groups.items) |*group| {
            group.files.deinit(self.gpa);
            group.children.deinit(self.gpa);
        }
        self.groups.deinit(self.gpa);
        self.by_path.deinit(self.gpa);
        if (self.file_groups.len > 0) self.gpa.free(self.file_groups);
        if (self.file_paths.len > 0) self.gpa.free(self.file_paths);
        if (self.file_visible.len > 0) self.gpa.free(self.file_visible);
        self.* = undefined;
    }

    pub fn groupOfFile(self: *const Hierarchy, file_idx: u32) u32 {
        return self.file_groups[file_idx];
    }

    pub fn isVisible(self: *const Hierarchy, file_idx: u32) bool {
        return self.file_visible[file_idx];
    }
};

pub fn build(model_ptr: *const Model) !Hierarchy {
    const gpa = model_ptr.gpa;
    const count = model_ptr.files.items.len;
    const labels = try gpa.alloc([]const u8, count);
    defer gpa.free(labels);
    const generated = try gpa.alloc(bool, count);
    defer gpa.free(generated);
    const cycles = try gpa.alloc(bool, count);
    defer gpa.free(cycles);
    const visible = try gpa.alloc(bool, count);
    defer gpa.free(visible);

    for (model_ptr.files.items, 0..) |file, i| {
        labels[i] = model_ptr.fileLabel(@intCast(i));
        generated[i] = file.generated;
        cycles[i] = file.in_import_cycle;
        visible[i] = !model_ptr.graphExcludes(labels[i]);
    }
    return buildPaths(gpa, labels, generated, cycles, visible);
}

pub fn buildPaths(
    gpa: Gpa,
    labels: []const []const u8,
    generated: []const bool,
    cycles: []const bool,
    visible: []const bool,
) !Hierarchy {
    std.debug.assert(labels.len == generated.len);
    std.debug.assert(labels.len == cycles.len);
    std.debug.assert(labels.len == visible.len);

    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(gpa);
    var facade_dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer facade_dirs.deinit(gpa);
    for (labels) |path| try addDirectories(gpa, &dirs, path);
    try collectFacadeDirs(gpa, labels, &dirs, &facade_dirs);

    const file_groups = try gpa.alloc(u32, labels.len);
    errdefer gpa.free(file_groups);
    const file_paths = try gpa.alloc([]const u8, labels.len);
    errdefer gpa.free(file_paths);
    @memcpy(file_paths, labels);
    const file_visible = try gpa.alloc(bool, labels.len);
    errdefer gpa.free(file_visible);
    @memcpy(file_visible, visible);

    var h = Hierarchy{
        .gpa = gpa,
        .file_groups = file_groups,
        .file_paths = file_paths,
        .file_visible = file_visible,
    };
    errdefer h.deinit();

    _ = try ensureGroup(&h, "");
    for (labels, 0..) |path, i| {
        const group_path = groupPathForFile(path, &facade_dirs);
        const group_id = try ensureGroup(&h, group_path);
        h.file_groups[i] = group_id;
        if (visible[i]) try h.groups.items[group_id].files.append(gpa, @intCast(i));
    }

    finalize(&h, generated, cycles);
    return h;
}

fn addDirectories(gpa: Gpa, dirs: *std.StringHashMapUnmanaged(void), path_raw: []const u8) !void {
    const path = stripDotSlash(path_raw);
    var dir = std.fs.path.dirname(path) orelse return;
    while (dir.len > 0 and !std.mem.eql(u8, dir, ".")) {
        if (dirs.contains(dir)) return;
        try dirs.put(gpa, dir, {});
        dir = std.fs.path.dirname(dir) orelse return;
    }
}

fn collectFacadeDirs(
    gpa: Gpa,
    labels: []const []const u8,
    dirs: *const std.StringHashMapUnmanaged(void),
    facade_dirs: *std.StringHashMapUnmanaged(void),
) !void {
    for (labels) |path_raw| {
        const path = stripDotSlash(path_raw);
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        const stem = path[0 .. path.len - 4];
        if (dirs.contains(stem)) try facade_dirs.put(gpa, stem, {});
    }
}

fn groupPathForFile(
    path_raw: []const u8,
    facade_dirs: *const std.StringHashMapUnmanaged(void),
) []const u8 {
    const path = stripDotSlash(path_raw);
    const dir = std.fs.path.dirname(path) orelse return "";
    if (std.mem.endsWith(u8, path, ".zig")) {
        const stem = path[0 .. path.len - 4];
        if (facade_dirs.contains(stem)) return displayPath(stem);
        if (std.mem.eql(u8, dir, "src")) return displayPath(stem);
    }
    const root = moduleRoot(dir);
    if (std.mem.eql(u8, root, dir)) return displayPath(root);
    var current = dir;
    while (!std.mem.eql(u8, current, root)) {
        if (facade_dirs.contains(current)) return displayPath(current);
        current = parentPath(current);
    }
    return displayPath(root);
}

fn moduleRoot(dir: []const u8) []const u8 {
    if (std.mem.startsWith(u8, dir, "src/")) {
        const rest = dir[4..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return dir;
        return dir[0 .. 4 + slash];
    }
    const slash = std.mem.indexOfScalar(u8, dir, '/') orelse return dir;
    return dir[0..slash];
}

fn displayPath(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "src/")) return path[4..];
    return path;
}

fn stripDotSlash(s: []const u8) []const u8 {
    var out = s;
    while (std.mem.startsWith(u8, out, "./")) out = out[2..];
    return out;
}

fn ensureGroup(self: *Hierarchy, path: []const u8) !u32 {
    if (self.by_path.get(path)) |id| return id;

    const parent_path = if (path.len == 0) null else parentPath(path);
    const parent_id = if (parent_path) |parent| try ensureGroup(self, parent) else null;
    const id: u32 = @intCast(self.groups.items.len);
    const name = if (path.len == 0) "(root)" else std.fs.path.basename(path);

    try self.groups.append(self.gpa, .{
        .path = path,
        .name = name,
        .parent = parent_id,
    });
    try self.by_path.put(self.gpa, path, id);
    if (parent_id) |parent| try self.groups.items[parent].children.append(self.gpa, id);
    return id;
}

fn parentPath(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return "";
    if (std.mem.eql(u8, dir, ".")) return "";
    return dir;
}

fn finalize(self: *Hierarchy, generated: []const bool, cycles: []const bool) void {
    computeStats(self, root_group, generated, cycles);
}

fn computeStats(self: *Hierarchy, group_idx: u32, generated: []const bool, cycles: []const bool) void {
    const group = &self.groups.items[group_idx];
    group.file_count = @intCast(group.files.items.len);
    group.generated_count = 0;
    group.cycle_files = 0;
    group.is_facade = false;

    for (group.files.items) |file_idx| {
        if (generated[file_idx]) group.generated_count += 1;
        if (cycles[file_idx]) group.cycle_files += 1;
        if (isFacadeFile(self, group_idx, file_idx)) group.is_facade = true;
    }
    for (group.children.items) |child| {
        computeStats(self, child, generated, cycles);
        const child_group = self.groups.items[child];
        group.file_count += child_group.file_count;
        group.generated_count += child_group.generated_count;
        group.cycle_files += child_group.cycle_files;
    }
    if (group.file_count <= 1) group.is_facade = false;
}

fn isFacadeFile(self: *const Hierarchy, group_idx: u32, file_idx: u32) bool {
    const group = self.groups.items[group_idx];
    const base = std.fs.path.basename(self.file_paths[file_idx]);
    if (!std.mem.endsWith(u8, base, ".zig")) return false;
    return std.mem.eql(u8, base[0 .. base.len - 4], group.name);
}

pub fn writeDetailed(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy) !void {
    var externals = try Externals.collect(h.gpa, model_ptr, h);
    defer externals.deinit();

    try w.writeAll("digraph imports {\n");
    try w.writeAll("  compound=true;\n");
    try w.writeAll("  graph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, nodesep=0.2, ranksep=0.4, labelloc=t];\n");
    try w.writeAll("  node [fontname=\"Helvetica\", fontsize=9];\n");
    try w.writeAll("  edge [fontname=\"Helvetica\", fontsize=7, arrowsize=0.7, color=\"#5b6b7c\"];\n");

    try writeGroup(w, model_ptr, h, root_group);
    try externals.writeNodes(w);
    try writeFileEdges(w, model_ptr, h);
    try writeExternalEdges(w, model_ptr, h, &externals);
    try w.writeAll("}\n");
}

fn writeGroup(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy, group_idx: u32) !void {
    const group = &h.groups.items[group_idx];
    if (group_idx != root_group) {
        try w.print("  subgraph cluster_g{d} {{\n", .{group_idx});
        try writeClusterAttrs(w, h, group);
    }
    for (group.files.items) |file_idx| try writeFileNode(w, model_ptr, file_idx);
    for (group.children.items) |child| {
        if (h.groups.items[child].file_count == 0) continue;
        try writeGroup(w, model_ptr, h, child);
    }
    if (group_idx != root_group) try w.writeAll("  }\n");
}

fn writeClusterAttrs(w: *std.Io.Writer, h: *const Hierarchy, group: *const Group) !void {
    try w.writeAll("    labeljust=\"l\";\n    fontname=\"Helvetica\";\n    fontsize=11;\n    margin=12;\n    style=\"rounded,filled\";\n");
    if (group.cycle_files > 0) {
        try w.writeAll("    fillcolor=\"#fffafa\";\n    color=\"#d93025\";\n    fontcolor=\"#a52714\";\n    penwidth=1.6;\n");
    } else if (group.file_count > 0 and group.generated_count == group.file_count) {
        try w.writeAll("    fillcolor=\"#f6f8fa\";\n    color=\"#8c959f\";\n    style=\"rounded,filled,dashed\";\n    fontcolor=\"#57606a\";\n");
    } else {
        try w.writeAll("    fillcolor=\"#fcfaff\";\n    color=\"#d8c2f5\";\n    fontcolor=\"#5b3a8f\";\n");
    }
    const kind = groupKind(group);
    var suffix: []const u8 = "";
    if (group.cycle_files > 0) suffix = " · cycle";
    if (group.file_count > 0 and group.generated_count == group.file_count) suffix = " · generated";
    const label = try std.fmt.allocPrint(h.gpa, "{s}\n{s} · {d} {s}{s}", .{
        group.name,
        kind,
        group.file_count,
        plural(group.file_count, "file", "files"),
        suffix,
    });
    try w.writeAll("    label=");
    try dotStr(w, label);
    try w.writeAll(";\n");
}

fn writeFileNode(w: *std.Io.Writer, model_ptr: *const Model, file_idx: u32) !void {
    const gpa = model_ptr.gpa;
    const file = model_ptr.files.items[file_idx];
    try w.print("  f{d} [shape=box, ", .{file_idx});
    if (file.generated) {
        try w.writeAll("style=\"rounded,filled,dashed\", fillcolor=\"#f6f8fa\", color=\"#8c959f\"");
    } else if (file.in_import_cycle) {
        try w.writeAll("style=\"rounded,filled\", fillcolor=\"#fbe9e7\", color=\"#d93025\", penwidth=1.6");
    } else {
        try w.writeAll("style=\"rounded,filled\", fillcolor=\"#f3e8fd\", color=\"#8250df\"");
    }
    var label = std.fs.path.basename(file.path);
    if (file.generated) label = try std.fmt.allocPrint(gpa, "{s} (generated)", .{label});
    try w.writeAll(", label=");
    try dotStr(w, label);
    try w.writeAll(", tooltip=");
    const tip = try std.fmt.allocPrint(gpa, "{s}\n{d} functions · {d} min debt", .{
        model_ptr.fileLabel(file_idx),
        file.fns.items.len,
        file.debt_min,
    });
    try dotStr(w, tip);
    try w.writeAll("];\n");
}

fn writeFileEdges(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy) !void {
    const gpa = model_ptr.gpa;
    for (model_ptr.files.items, 0..) |file, file_idx| {
        if (!h.file_visible[file_idx]) continue;
        for (file.imports.items) |imp| {
            if (imp.excluded) continue;
            const target = imp.resolved orelse continue;
            if (!h.file_visible[target]) continue;
            const target_file = model_ptr.files.items[target];
            try w.print("  f{d} -> f{d} [", .{ file_idx, target });
            if (target_file.generated) {
                try w.writeAll("style=dashed, color=\"#8c959f\"");
            } else if (file.cycle_id != null and file.cycle_id == target_file.cycle_id) {
                try w.writeAll("color=\"#d93025\", penwidth=1.6");
            }
            if (target_file.generated or (file.cycle_id != null and file.cycle_id == target_file.cycle_id)) {
                try w.writeAll(", ");
            }
            try w.writeAll("tooltip=");
            const tip = try std.fmt.allocPrint(gpa, "{s}:{d} → {s}", .{
                model_ptr.fileLabel(@intCast(file_idx)),
                imp.line,
                model_ptr.fileLabel(target),
            });
            try dotStr(w, tip);
            try w.writeAll("];\n");
        }
    }
}

fn writeExternalEdges(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy, externals: *const Externals) !void {
    const gpa = model_ptr.gpa;
    for (model_ptr.files.items, 0..) |file, file_idx| {
        if (!h.file_visible[file_idx]) continue;
        for (file.imports.items) |imp| {
            if (imp.excluded or imp.resolved != null) continue;
            if (Model.isExternalImport(imp.raw)) continue;
            const ext_id = externals.id(imp.raw) orelse continue;
            try w.print("  f{d} -> ext{d} [style=dashed, color=\"#e37400\", tooltip=", .{ file_idx, ext_id });
            const tip = try std.fmt.allocPrint(gpa, "{s}:{d} → {s}", .{
                model_ptr.fileLabel(@intCast(file_idx)),
                imp.line,
                imp.raw,
            });
            try dotStr(w, tip);
            try w.writeAll("];\n");
        }
    }
}

pub const Box = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const Layout = struct {
    gpa: Gpa,
    boxes: std.AutoHashMapUnmanaged(u64, Box) = .empty,
    width: f64 = 0,
    height: f64 = 0,

    pub fn empty(gpa: Gpa) Layout {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Layout) void {
        self.boxes.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn load(gpa: Gpa, io: Io, dot_path: []const u8) !Layout {
        const argv = [_][]const u8{ "dot", "-Tplain", dot_path };
        const result = try std.process.run(gpa, io, .{ .argv = &argv });
        defer gpa.free(result.stderr);
        defer gpa.free(result.stdout);
        if (!result.term.success()) return error.GraphvizFailed;
        return parsePlain(gpa, result.stdout);
    }

    pub fn fileBox(self: *const Layout, file_idx: u32) ?Box {
        return self.boxes.get(@as(u64, file_idx));
    }

    pub fn externalBox(self: *const Layout, ext_idx: u32) ?Box {
        return self.boxes.get(externalKey(ext_idx));
    }
};

fn externalKey(ext_idx: u32) u64 {
    return (@as(u64, 1) << 32) | @as(u64, ext_idx);
}

fn parsePlain(gpa: Gpa, source: []const u8) !Layout {
    var layout = Layout.empty(gpa);
    errdefer layout.deinit();

    var graph_height: f64 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const tag = tokens.next() orelse continue;
        if (std.mem.eql(u8, tag, "graph")) {
            _ = tokens.next() orelse continue;
            const width = parseFloatToken(&tokens) catch continue;
            const height = parseFloatToken(&tokens) catch continue;
            layout.width = width * 72.0;
            layout.height = height * 72.0;
            graph_height = height;
        } else if (std.mem.eql(u8, tag, "node")) {
            const name = tokens.next() orelse continue;
            const x = parseFloatToken(&tokens) catch continue;
            const y = parseFloatToken(&tokens) catch continue;
            const w = parseFloatToken(&tokens) catch continue;
            const h = parseFloatToken(&tokens) catch continue;
            const key = nodeKey(name) orelse continue;
            try layout.boxes.put(gpa, key, .{
                .x = (x - w * 0.5) * 72.0,
                .y = (graph_height - (y + h * 0.5)) * 72.0,
                .w = w * 72.0,
                .h = h * 72.0,
            });
        }
    }
    return layout;
}

fn parseFloatToken(tokens: anytype) !f64 {
    const text = tokens.next() orelse return error.InvalidPlain;
    return std.fmt.parseFloat(f64, text);
}

fn nodeKey(name: []const u8) ?u64 {
    if (std.mem.startsWith(u8, name, "ext")) {
        const id = std.fmt.parseUnsigned(u32, name[3..], 10) catch return null;
        return externalKey(id);
    }
    if (std.mem.startsWith(u8, name, "f")) {
        const id = std.fmt.parseUnsigned(u32, name[1..], 10) catch return null;
        return @as(u64, id);
    }
    return null;
}

pub fn writePayload(
    w: *std.Io.Writer,
    model_ptr: *const Model,
    h: *const Hierarchy,
    layout: *const Layout,
) !void {
    var externals = try Externals.collect(h.gpa, model_ptr, h);
    defer externals.deinit();

    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("groups");
    try writeGroups(&s, h);
    try s.objectField("nodes");
    try writeNodes(&s, model_ptr, h, layout);
    try s.objectField("externals");
    try writeExternals(&s, layout, &externals);
    try s.objectField("edges");
    try writePayloadEdges(&s, model_ptr, h);
    try s.objectField("externalEdges");
    try writePayloadExternalEdges(&s, model_ptr, h, &externals);
    try s.endObject();
}

fn writeGroups(s: *std.json.Stringify, h: *const Hierarchy) !void {
    try s.beginArray();
    for (h.groups.items, 0..) |group, group_idx| {
        if (group_idx != root_group and group.file_count == 0) continue;
        try s.beginObject();
        try s.objectField("id");
        try s.write(@as(u32, @intCast(group_idx)));
        try s.objectField("parent");
        try s.write(group.parent);
        try s.objectField("name");
        try s.write(group.name);
        try s.objectField("path");
        try s.write(group.path);
        try s.objectField("kind");
        try s.write(groupKind(&group));
        try s.objectField("fileCount");
        try s.write(group.file_count);
        try s.objectField("generated");
        try s.write(group.file_count > 0 and group.generated_count == group.file_count);
        try s.objectField("cycle");
        try s.write(group.cycle_files > 0);
        try s.objectField("facade");
        try s.write(group.is_facade);
        try s.endObject();
    }
    try s.endArray();
}

fn groupKind(group: *const Group) []const u8 {
    if (group.parent == null) return "root";
    if (group.is_facade) return "facade";
    if (group.parent.? != root_group) return "submodule";
    return "module";
}

fn writeNodes(s: *std.json.Stringify, model_ptr: *const Model, h: *const Hierarchy, layout: *const Layout) !void {
    try s.beginArray();
    for (model_ptr.files.items, 0..) |file, file_idx| {
        if (!h.file_visible[file_idx]) continue;
        const box = layout.fileBox(@intCast(file_idx)) orelse Box{
            .x = @as(f64, @floatFromInt(file_idx % 10)) * 190.0,
            .y = @as(f64, @floatFromInt(file_idx / 10)) * 90.0,
            .w = 160.0,
            .h = 34.0,
        };
        try s.beginObject();
        try s.objectField("id");
        try s.write(@as(u32, @intCast(file_idx)));
        try s.objectField("group");
        try s.write(h.file_groups[file_idx]);
        try s.objectField("label");
        try s.write(std.fs.path.basename(file.path));
        try s.objectField("path");
        try s.write(model_ptr.fileLabel(@intCast(file_idx)));
        try s.objectField("x");
        try s.write(box.x);
        try s.objectField("y");
        try s.write(box.y);
        try s.objectField("w");
        try s.write(box.w);
        try s.objectField("h");
        try s.write(box.h);
        try s.objectField("generated");
        try s.write(file.generated);
        try s.objectField("cycle");
        try s.write(file.in_import_cycle);
        try s.objectField("functions");
        try s.write(@as(u32, @intCast(file.fns.items.len)));
        try s.objectField("debt");
        try s.write(file.debt_min);
        try s.endObject();
    }
    try s.endArray();
}

fn writeExternals(s: *std.json.Stringify, layout: *const Layout, externals: *const Externals) !void {
    try s.beginArray();
    for (externals.names.items, 0..) |name, ext_idx| {
        const box = layout.externalBox(@intCast(ext_idx)) orelse Box{
            .x = @as(f64, @floatFromInt(ext_idx % 5)) * 150.0,
            .y = -120.0,
            .w = 130.0,
            .h = 30.0,
        };
        try s.beginObject();
        try s.objectField("id");
        try s.write(@as(u32, @intCast(ext_idx)));
        try s.objectField("label");
        try s.write(name);
        try s.objectField("x");
        try s.write(box.x);
        try s.objectField("y");
        try s.write(box.y);
        try s.objectField("w");
        try s.write(box.w);
        try s.objectField("h");
        try s.write(box.h);
        try s.endObject();
    }
    try s.endArray();
}

fn writePayloadEdges(s: *std.json.Stringify, model_ptr: *const Model, h: *const Hierarchy) !void {
    try s.beginArray();
    for (model_ptr.files.items, 0..) |file, file_idx| {
        if (!h.file_visible[file_idx]) continue;
        for (file.imports.items) |imp| {
            if (imp.excluded) continue;
            const target = imp.resolved orelse continue;
            if (!h.file_visible[target]) continue;
            try writePayloadEdge(s, @intCast(file_idx), target, file.cycle_id != null and file.cycle_id == model_ptr.files.items[target].cycle_id, model_ptr.files.items[target].generated);
        }
    }
    try s.endArray();
}

fn writePayloadEdge(s: *std.json.Stringify, from: u32, to: u32, cycle: bool, generated: bool) !void {
    try s.beginObject();
    try s.objectField("from");
    try s.write(from);
    try s.objectField("to");
    try s.write(to);
    try s.objectField("cycle");
    try s.write(cycle);
    try s.objectField("generated");
    try s.write(generated);
    try s.endObject();
}

fn writePayloadExternalEdges(s: *std.json.Stringify, model_ptr: *const Model, h: *const Hierarchy, externals: *const Externals) !void {
    try s.beginArray();
    for (model_ptr.files.items, 0..) |file, file_idx| {
        if (!h.file_visible[file_idx]) continue;
        for (file.imports.items) |imp| {
            if (imp.excluded or imp.resolved != null) continue;
            if (Model.isExternalImport(imp.raw)) continue;
            const ext_id = externals.id(imp.raw) orelse continue;
            try s.beginObject();
            try s.objectField("from");
            try s.write(@as(u32, @intCast(file_idx)));
            try s.objectField("to");
            try s.write(ext_id);
            try s.endObject();
        }
    }
    try s.endArray();
}

const Externals = struct {
    gpa: Gpa,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,

    fn collect(gpa: Gpa, model_ptr: *const Model, h: *const Hierarchy) !Externals {
        var externals = Externals{ .gpa = gpa };
        errdefer externals.deinit();
        for (model_ptr.files.items, 0..) |file, file_idx| {
            if (!h.file_visible[file_idx]) continue;
            for (file.imports.items) |imp| {
                if (imp.excluded or imp.resolved != null) continue;
                if (Model.isExternalImport(imp.raw)) continue;
                if (externals.by_name.contains(imp.raw)) continue;
                const ext_id: u32 = @intCast(externals.names.items.len);
                try externals.names.append(gpa, imp.raw);
                try externals.by_name.put(gpa, imp.raw, ext_id);
            }
        }
        return externals;
    }

    fn deinit(self: *Externals) void {
        self.names.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.* = undefined;
    }

    fn id(self: *const Externals, name: []const u8) ?u32 {
        return self.by_name.get(name);
    }

    fn writeNodes(self: *const Externals, w: *std.Io.Writer) !void {
        for (self.names.items, 0..) |name, i| {
            try w.print("  ext{d} [shape=note, style=\"dashed,filled\", fillcolor=\"#fff3cd\", color=\"#e37400\", label=", .{i});
            try dotStr(w, name);
            try w.writeAll(", tooltip=\"unresolved module import\"];\n");
        }
    }
};

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

fn plural(n: u32, one: []const u8, many: []const u8) []const u8 {
    return if (n == 1) one else many;
}

test "facade grouping follows module and submodule directories" {
    const paths = [_][]const u8{
        "build.zig",
        "src/codegen.zig",
        "src/codegen/emit.zig",
        "src/editor.zig",
        "src/editor/api.zig",
        "src/editor/graph.zig",
        "src/editor/graph/edge.zig",
        "src/main.zig",
        "customworkflows/run.zig",
        "src/cli/support/io.zig",
        "src/proto_gen/orchengine/events/v1.pb.zig",
    };
    const generated: [paths.len]bool = @splat(false);
    const cycles: [paths.len]bool = @splat(false);
    const visible: [paths.len]bool = @splat(true);

    var h = try buildPaths(std.testing.allocator, &paths, &generated, &cycles, &visible);
    defer h.deinit();

    const codegen = h.groupOfFile(1);
    try std.testing.expectEqualStrings("codegen", h.groups.items[codegen].path);
    try std.testing.expectEqual(codegen, h.groupOfFile(2));
    try std.testing.expect(h.groups.items[codegen].is_facade);

    const editor = h.groupOfFile(3);
    try std.testing.expectEqualStrings("editor", h.groups.items[editor].path);
    try std.testing.expectEqual(editor, h.groupOfFile(4));
    try std.testing.expectEqual(editor, h.groups.items[h.groupOfFile(5)].parent.?);
    try std.testing.expectEqualStrings("editor/graph", h.groups.items[h.groupOfFile(6)].path);
    try std.testing.expectEqual(h.groupOfFile(5), h.groupOfFile(6));

    try std.testing.expectEqualStrings("main", h.groups.items[h.groupOfFile(7)].path);
    try std.testing.expectEqual(root_group, h.groupOfFile(0));
    try std.testing.expectEqualStrings("customworkflows", h.groups.items[h.groupOfFile(8)].path);
    try std.testing.expectEqualStrings("cli", h.groups.items[h.groupOfFile(9)].path);
    try std.testing.expectEqualStrings("proto_gen", h.groups.items[h.groupOfFile(10)].path);
}

test "graph exclusions keep analysis but hide files from the graph" {
    const paths = [_][]const u8{
        "src/main.zig",
        "src/unit_tests.zig",
        "src/codegen.zig",
        "src/codegen/emit.zig",
    };
    const generated: [paths.len]bool = @splat(false);
    const cycles: [paths.len]bool = @splat(false);
    const visible = [_]bool{ true, false, true, true };

    var h = try buildPaths(std.testing.allocator, &paths, &generated, &cycles, &visible);
    defer h.deinit();

    try std.testing.expect(!h.isVisible(1));
    try std.testing.expect(h.isVisible(0));
    try std.testing.expectEqual(@as(u32, 1), h.groups.items[h.groupOfFile(0)].file_count);
    try std.testing.expectEqual(@as(u32, 2), h.groups.items[h.groupOfFile(2)].file_count);
}

test "detailed graph nests submodules inside facades" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m = Model{
        .gpa = alloc,
        .root = "",
        .title = "test",
        .settings = .{},
    };
    _ = try m.addFile("src/editor.zig", "");
    _ = try m.addFile("src/editor/api.zig", "");
    _ = try m.addFile("src/editor/graph.zig", "");
    _ = try m.addFile("src/editor/graph/edge.zig", "");

    var h = try build(&m);
    defer h.deinit();

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try writeDetailed(&aw.writer, &m, &h);
    const dot = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, dot, "digraph imports") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "compound=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"editor\\nfacade · 4 files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"graph\\nfacade · 2 files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"graph.zig\"") != null);
}

test "parse graphviz plain layout" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const plain =
        \\graph 1 10 5
        \\node f0 2 4 1 0.5 "a.zig" rounded,filled box #8250df #f3e8fd
        \\node ext0 8 2 0.5 0.5 "mod" dashed filled note #e37400 #fff3cd
        \\stop
    ;
    var layout = try parsePlain(alloc, plain);
    defer layout.deinit();

    const file = layout.fileBox(0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 108), file.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 54), file.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 72), file.w, 0.01);

    const ext = layout.externalBox(0).?;
    try std.testing.expectApproxEqAbs(@as(f64, 558), ext.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 198), ext.y, 0.01);
}

test "payload embeds hierarchy and visible edges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var m = Model{
        .gpa = alloc,
        .root = "",
        .title = "test",
        .settings = .{},
    };
    _ = try m.addFile("src/a.zig", "");
    _ = try m.addFile("src/a/one.zig", "");
    _ = try m.addFile("src/unit_tests.zig", "");
    try m.config.graph_exclude.append(alloc, "src/unit_tests.zig");
    try m.files.items[0].imports.append(alloc, .{ .raw = "a/one.zig", .line = 2, .resolved = 1 });

    var h = try build(&m);
    defer h.deinit();
    var layout = Layout.empty(alloc);
    defer layout.deinit();

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try writePayload(&aw.writer, &m, &h, &layout);
    const json = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, json, "\"groups\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nodes\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "src/unit_tests.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"from\":0") != null);
}
