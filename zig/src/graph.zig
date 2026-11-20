//! Dependency graph hierarchy and Graphviz output.
//!
//! Facades follow the repository convention: `src/<module>.zig` is the public
//! facade and `src/<module>/` contains its internals. The hierarchy nests
//! submodules below their parent module. The detailed graph renders files
//! inside those clusters; the facade graph rolls nested modules up and
//! aggregates cross-module edges for the zoomed-out view.

const std = @import("std");
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

    pub fn deinit(self: *Hierarchy) void {
        for (self.groups.items) |*group| {
            group.files.deinit(self.gpa);
            group.children.deinit(self.gpa);
        }
        self.groups.deinit(self.gpa);
        self.by_path.deinit(self.gpa);
        if (self.file_groups.len > 0) self.gpa.free(self.file_groups);
        if (self.file_paths.len > 0) self.gpa.free(self.file_paths);
        self.* = undefined;
    }

    pub fn groupOfFile(self: *const Hierarchy, file_idx: u32) u32 {
        return self.file_groups[file_idx];
    }

    /// The top-level module that owns a group. Root files stay in the root.
    pub fn topGroup(self: *const Hierarchy, group_idx: u32) u32 {
        var current = group_idx;
        while (self.groups.items[current].parent) |parent| {
            if (parent == root_group) break;
            current = parent;
        }
        return current;
    }

    pub fn topGroupOfFile(self: *const Hierarchy, file_idx: u32) u32 {
        return self.topGroup(self.groupOfFile(file_idx));
    }
};

pub fn build(model_ptr: *const Model) !Hierarchy {
    const gpa = model_ptr.gpa;
    const labels = try gpa.alloc([]const u8, model_ptr.files.items.len);
    defer gpa.free(labels);
    const generated = try gpa.alloc(bool, model_ptr.files.items.len);
    defer gpa.free(generated);
    const cycles = try gpa.alloc(bool, model_ptr.files.items.len);
    defer gpa.free(cycles);

    for (model_ptr.files.items, 0..) |file, i| {
        labels[i] = model_ptr.fileLabel(@intCast(i));
        generated[i] = file.generated;
        cycles[i] = file.in_import_cycle;
    }
    return buildPaths(gpa, labels, generated, cycles);
}

pub fn buildPaths(
    gpa: Gpa,
    labels: []const []const u8,
    generated: []const bool,
    cycles: []const bool,
) !Hierarchy {
    std.debug.assert(labels.len == generated.len);
    std.debug.assert(labels.len == cycles.len);

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

    var h = Hierarchy{
        .gpa = gpa,
        .file_groups = file_groups,
        .file_paths = file_paths,
    };
    errdefer h.deinit();

    _ = try ensureGroup(&h, "");
    for (labels, 0..) |path, i| {
        const group_path = groupPathForFile(path, &facade_dirs);
        const group_id = try ensureGroup(&h, group_path);
        h.file_groups[i] = group_id;
        try h.groups.items[group_id].files.append(gpa, @intCast(i));
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
    var externals = try Externals.collect(h.gpa, model_ptr);
    defer externals.deinit();

    try w.writeAll("digraph imports {\n");
    try w.writeAll("  compound=true;\n");
    try w.writeAll("  graph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, nodesep=0.2, ranksep=0.4, labelloc=t];\n");
    try w.writeAll("  node [fontname=\"Helvetica\", fontsize=9];\n");
    try w.writeAll("  edge [fontname=\"Helvetica\", fontsize=7, arrowsize=0.7, color=\"#5b6b7c\"];\n");

    try writeGroup(w, model_ptr, h, root_group);
    try externals.writeNodes(w);
    try writeFileEdges(w, model_ptr);
    try writeExternalEdges(w, model_ptr, &externals);
    try w.writeAll("}\n");
}

fn writeGroup(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy, group_idx: u32) !void {
    const group = &h.groups.items[group_idx];
    if (group_idx != root_group) {
        try w.print("  subgraph cluster_g{d} {{\n", .{group_idx});
        try writeClusterAttrs(w, h, group);
    }
    for (group.files.items) |file_idx| try writeFileNode(w, model_ptr, file_idx);
    for (group.children.items) |child| try writeGroup(w, model_ptr, h, child);
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
    const kind = if (group.is_facade) "facade" else if (group.parent != null and group.parent.? != root_group) "submodule" else "module";
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

fn writeFileEdges(w: *std.Io.Writer, model_ptr: *const Model) !void {
    const gpa = model_ptr.gpa;
    for (model_ptr.files.items, 0..) |file, file_idx| {
        for (file.imports.items) |imp| {
            if (imp.excluded) continue;
            const target = imp.resolved orelse continue;
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

fn writeExternalEdges(w: *std.Io.Writer, model_ptr: *const Model, externals: *const Externals) !void {
    const gpa = model_ptr.gpa;
    for (model_ptr.files.items, 0..) |file, file_idx| {
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

pub fn writeFacades(w: *std.Io.Writer, model_ptr: *const Model, h: *const Hierarchy) !void {
    var externals = try Externals.collect(h.gpa, model_ptr);
    defer externals.deinit();
    const tops = try collectTops(h, h.gpa);
    defer h.gpa.free(tops);

    var edges: std.AutoHashMapUnmanaged(u64, EdgeStats) = .empty;
    defer edges.deinit(h.gpa);
    var external_edges: std.AutoHashMapUnmanaged(u64, EdgeStats) = .empty;
    defer external_edges.deinit(h.gpa);
    try aggregateEdges(model_ptr, h, &externals, &edges, &external_edges);

    try w.writeAll("digraph facades {\n");
    try w.writeAll("  graph [rankdir=LR, bgcolor=\"white\", fontname=\"Helvetica\", fontsize=10, nodesep=0.2, ranksep=0.4, labelloc=t];\n");
    try w.writeAll("  node [fontname=\"Helvetica\", fontsize=10];\n");
    try w.writeAll("  edge [fontname=\"Helvetica\", fontsize=8, arrowsize=0.7, color=\"#5b6b7c\"];\n");

    try writeFacadeNodes(w, h, tops);
    try externals.writeNodes(w);
    try writeFacadeEdges(w, h, tops, &edges);
    try writeFacadeExternalEdges(w, h, tops, &externals, &external_edges);
    try w.writeAll("}\n");
}

const EdgeStats = struct {
    count: u32 = 0,
    cycle: u32 = 0,
    generated: u32 = 0,
};

fn collectTops(h: *const Hierarchy, gpa: Gpa) ![]u32 {
    var tops: std.ArrayListUnmanaged(u32) = .empty;
    errdefer tops.deinit(gpa);
    for (h.groups.items, 0..) |group, group_idx| {
        const is_top = group_idx == root_group or group.parent == root_group;
        if (!is_top) continue;
        const count = if (group_idx == root_group) group.files.items.len else group.file_count;
        if (count == 0) continue;
        try tops.append(gpa, @intCast(group_idx));
    }
    return tops.toOwnedSlice(gpa);
}

fn aggregateEdges(
    model_ptr: *const Model,
    h: *const Hierarchy,
    externals: *const Externals,
    edges: *std.AutoHashMapUnmanaged(u64, EdgeStats),
    external_edges: *std.AutoHashMapUnmanaged(u64, EdgeStats),
) !void {
    for (model_ptr.files.items, 0..) |file, file_idx| {
        const from = h.topGroupOfFile(@intCast(file_idx));
        for (file.imports.items) |imp| {
            if (imp.excluded) continue;
            if (imp.resolved) |target| {
                const to = h.topGroupOfFile(target);
                if (from == to) continue;
                const stats = try getEdgeStats(h.gpa, edges, edgeKey(from, to));
                stats.count += 1;
                if (file.cycle_id != null and file.cycle_id == model_ptr.files.items[target].cycle_id) {
                    stats.cycle += 1;
                }
                if (model_ptr.files.items[target].generated) stats.generated += 1;
            } else if (!Model.isExternalImport(imp.raw)) {
                const ext_id = externals.id(imp.raw) orelse continue;
                const stats = try getEdgeStats(h.gpa, external_edges, edgeKey(from, ext_id));
                stats.count += 1;
            }
        }
    }
}

fn getEdgeStats(gpa: Gpa, map: *std.AutoHashMapUnmanaged(u64, EdgeStats), key: u64) !*EdgeStats {
    const gop = try map.getOrPut(gpa, key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

fn edgeKey(from: u32, to: u32) u64 {
    return (@as(u64, from) << 32) | @as(u64, to);
}

fn writeFacadeNodes(w: *std.Io.Writer, h: *const Hierarchy, tops: []const u32) !void {
    for (tops) |group_idx| {
        const group = h.groups.items[group_idx];
        const is_root = group_idx == root_group;
        try w.print("  fg{d} [shape=box, ", .{group_idx});
        if (!is_root and group.cycle_files > 0) {
            try w.writeAll("style=\"rounded,filled\", fillcolor=\"#fbe9e7\", color=\"#d93025\", penwidth=1.6");
        } else if (!is_root and group.file_count > 0 and group.generated_count == group.file_count) {
            try w.writeAll("style=\"rounded,filled,dashed\", fillcolor=\"#f6f8fa\", color=\"#8c959f\"");
        } else if (is_root) {
            try w.writeAll("style=\"rounded,filled\", fillcolor=\"#eef2f7\", color=\"#8c959f\"");
        } else {
            try w.writeAll("style=\"rounded,filled\", fillcolor=\"#f3e8fd\", color=\"#8250df\"");
        }
        const count: u32 = if (is_root) @intCast(group.files.items.len) else group.file_count;
        const kind = if (is_root) "root" else if (group.is_facade) "facade" else "module";
        var suffix: []const u8 = "";
        if (!is_root and group.cycle_files > 0) suffix = " · cycle";
        if (!is_root and group.file_count > 0 and group.generated_count == group.file_count) suffix = " · generated";
        const label = try std.fmt.allocPrint(h.gpa, "{s}\n{d} {s} · {s}{s}", .{
            group.name,
            count,
            plural(count, "file", "files"),
            kind,
            suffix,
        });
        try w.writeAll(", label=");
        try dotStr(w, label);
        try w.writeAll(", tooltip=");
        try dotStr(w, if (is_root) "files at the repository root" else group.path);
        try w.writeAll("];\n");
    }
}

fn writeFacadeEdges(
    w: *std.Io.Writer,
    h: *const Hierarchy,
    tops: []const u32,
    edges: *const std.AutoHashMapUnmanaged(u64, EdgeStats),
) !void {
    for (tops) |from| {
        for (tops) |to| {
            if (from == to) continue;
            const stats = edges.get(edgeKey(from, to)) orelse continue;
            try w.print("  fg{d} -> fg{d} [", .{ from, to });
            try writeAggregateAttrs(w, h, from, to, stats);
            try w.writeAll("];\n");
        }
    }
}

fn writeFacadeExternalEdges(
    w: *std.Io.Writer,
    h: *const Hierarchy,
    tops: []const u32,
    externals: *const Externals,
    edges: *const std.AutoHashMapUnmanaged(u64, EdgeStats),
) !void {
    for (tops) |from| {
        for (externals.names.items, 0..) |name, ext_idx| {
            const stats = edges.get(edgeKey(from, @intCast(ext_idx))) orelse continue;
            try w.print("  fg{d} -> ext{d} [style=dashed, color=\"#e37400\", tooltip=", .{ from, ext_idx });
            const tip = try std.fmt.allocPrint(h.gpa, "{s} → {s}: {d} imports", .{
                h.groups.items[from].name,
                name,
                stats.count,
            });
            try dotStr(w, tip);
            if (stats.count > 1) {
                try w.writeAll(", label=");
                const label = try std.fmt.allocPrint(h.gpa, "{d}", .{stats.count});
                try dotStr(w, label);
            }
            try w.writeAll("];\n");
        }
    }
}

fn writeAggregateAttrs(
    w: *std.Io.Writer,
    h: *const Hierarchy,
    from: u32,
    to: u32,
    stats: EdgeStats,
) !void {
    const styled = try writeAggregateStyle(w, stats);
    if (styled) try w.writeAll(", ");
    if (stats.count > 1) {
        try w.writeAll("label=");
        const label = try std.fmt.allocPrint(h.gpa, "{d}", .{stats.count});
        try dotStr(w, label);
        try w.writeAll(", ");
    }
    try w.writeAll("tooltip=");
    const tip = try std.fmt.allocPrint(h.gpa, "{s} → {s}: {d} imports, {d} cyclic", .{
        h.groups.items[from].name,
        h.groups.items[to].name,
        stats.count,
        stats.cycle,
    });
    try dotStr(w, tip);
}

fn writeAggregateStyle(w: *std.Io.Writer, stats: EdgeStats) !bool {
    if (stats.cycle > 0) {
        try w.writeAll("color=\"#d93025\", penwidth=1.6");
        return true;
    }
    if (stats.count > 0 and stats.generated == stats.count) {
        try w.writeAll("style=dashed, color=\"#8c959f\"");
        return true;
    }
    return false;
}

const Externals = struct {
    gpa: Gpa,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,

    fn collect(gpa: Gpa, model_ptr: *const Model) !Externals {
        var externals = Externals{ .gpa = gpa };
        errdefer externals.deinit();
        for (model_ptr.files.items) |file| {
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

    var h = try buildPaths(std.testing.allocator, &paths, &generated, &cycles);
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
    try std.testing.expectEqual(h.groupOfFile(3), h.topGroupOfFile(6));
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

test "facade graph aggregates cross-module imports" {
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
    _ = try m.addFile("src/b.zig", "");
    try m.files.items[0].imports.append(alloc, .{ .raw = "../b.zig", .line = 3, .resolved = 2 });
    try m.files.items[1].imports.append(alloc, .{ .raw = "../b.zig", .line = 4, .resolved = 2 });

    var h = try build(&m);
    defer h.deinit();

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try writeFacades(&aw.writer, &m, &h);
    const dot = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, dot, "digraph facades") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"a\\n2 files · facade\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"2\"") != null);
}
