const std = @import("std");
const Ast = std.zig.Ast;

pub const Gpa = std.mem.Allocator;
pub const no_fn = std.math.maxInt(u32);

pub const Severity = enum {
    @"error",
    warning,
    note,
};

pub const FindingSource = enum {
    zlint,
    project,
};

pub const Finding = struct {
    rule_id: []const u8,
    severity: Severity,
    message: []const u8,
    path: []const u8,
    line: u32 = 0,
    end_line: u32 = 0,
    source: FindingSource,
    weight: u32 = 0,
    suppressed: bool = false,
    suppression_reason: ?[]const u8 = null,
};

pub const Settings = struct {
    max_call_nodes: usize = 80,
    min_debt: u32 = 0,
};

pub const Confidence = enum {
    same_file,
    alias,
    method,
    global,
    unresolved,
    external,
};

pub const CapSource = enum {
    none,
    param,
    field,
    local,
    global,
    inherited,
};

pub const AccessKind = enum {
    read,
    write,
    read_write,
};

pub const FieldInfo = struct {
    name: []const u8,
    type_text: []const u8,
    container: []const u8,
    file: u32,
    line: u32,
    reads: u32 = 0,
    writes: u32 = 0,
    is_pointer: bool = false,
    is_slice: bool = false,
    is_allocator: bool = false,
    is_io: bool = false,
};

pub const TypeInfo = struct {
    name: []const u8,
    file: u32,
    line: u32,
    fields: std.ArrayList(u32) = .empty,
    has_init: bool = false,
    has_deinit: bool = false,
};

pub const FieldAccess = struct {
    fn_idx: u32,
    type_id: u32,
    field_id: u32,
    line: u32,
    kind: AccessKind,
};

pub const Config = struct {
    exclude: std.ArrayList([]const u8) = .empty,
    generated_paths: std.ArrayList([]const u8) = .empty,
    generated_markers: std.ArrayList([]const u8) = .empty,
    include_generated_metrics: bool = false,
    debug_io: bool = false,
    track_capabilities: bool = true,
    track_fields: bool = true,
    rule_weights: std.StringHashMapUnmanaged(u32) = .empty,
    default_error_weight: u32 = 10,
    default_warning_weight: u32 = 1,
    default_note_weight: u32 = 0,
};

pub const SkippedFile = struct {
    path: []const u8,
    reason: []const u8,
};

pub const Import = struct {
    raw: []const u8,
    alias: ?[]const u8 = null,
    line: u32,
    resolved: ?u32 = null,
    excluded: bool = false,
};

pub const Call = struct {
    name: []const u8,
    receiver: ?[]const u8,
    line: u32,
    caller: ?u32,
    resolved: ?u32 = null,
    confidence: Confidence = .unresolved,
};

pub const FnInfo = struct {
    name: []const u8,
    parent: ?[]const u8 = null,
    parent_allocator: bool = false,
    parent_io: bool = false,
    file: u32,
    line: u32,
    end_line: u32,
    start: u32,
    end: u32,
    params: u32,
    complexity: u32,
    nesting: u32,
    loc: u32,
    is_pub: bool,
    has_doc: bool,
    debt_min: u32 = 0,
    in_call_cycle: bool = false,
    cycle_id: ?u32 = null,
    sig_allocator: bool = false,
    sig_io: bool = false,
    direct_allocator: bool = false,
    direct_io: bool = false,
    inherited_allocator: bool = false,
    inherited_io: bool = false,
    needs_allocator: bool = false,
    needs_io: bool = false,
    debug_io: bool = false,
    logging: bool = false,
    alloc_source: CapSource = .none,
    io_source: CapSource = .none,
    /// Call-site indices owned by this function.
    call_sites: std.ArrayList(u32) = .empty,
    /// Caller function ids that resolve to this function.
    callers: std.ArrayList(u32) = .empty,
};

pub const FileInfo = struct {
    path: []const u8,
    dir: []const u8,
    source: []const u8,
    parse_errors: u32 = 0,
    generated: bool = false,
    generated_reason: ?[]const u8 = null,
    fns: std.ArrayList(u32) = .empty,
    imports: std.ArrayList(Import) = .empty,
    fn_names: std.StringHashMapUnmanaged(u32) = .empty,
    type_names: std.StringHashMapUnmanaged(u32) = .empty,
    aliases: std.StringHashMapUnmanaged(u32) = .empty,
    todo_count: u32 = 0,
    debug_output_count: u32 = 0,
    unreachable_count: u32 = 0,
    swallow_count: u32 = 0,
    ptr_cast_count: u32 = 0,
    align_cast_count: u32 = 0,
    const_cast_count: u32 = 0,
    from_int_count: u32 = 0,
    debt_min: u32 = 0,
    in_import_cycle: bool = false,
    cycle_id: ?u32 = null,
};

pub const ModuleImport = struct {
    raw: []const u8,
    file: u32,
    line: u32,
};

pub const Cycle = struct {
    nodes: []u32,
};

pub const Chain = struct {
    root: u32,
    nodes: []u32,
};

pub const Model = struct {
    gpa: Gpa,
    root: []const u8,
    title: []const u8,
    settings: Settings,
    config: Config = .{},
    excluded_files: std.ArrayList(SkippedFile) = .empty,
    excluded_by_path: std.StringHashMapUnmanaged([]const u8) = .empty,
    list_files: bool = false,
    files: std.ArrayList(FileInfo) = .empty,
    fns: std.ArrayList(FnInfo) = .empty,
    calls: std.ArrayList(Call) = .empty,
    types: std.ArrayList(TypeInfo) = .empty,
    fields: std.ArrayList(FieldInfo) = .empty,
    field_accesses: std.ArrayList(FieldAccess) = .empty,
    file_by_path: std.StringHashMapUnmanaged(u32) = .empty,
    global_fn: std.StringHashMapUnmanaged(u32) = .empty,
    module_imports: std.ArrayList(ModuleImport) = .empty,
    import_cycles: std.ArrayList(Cycle) = .empty,
    call_cycles: std.ArrayList(Cycle) = .empty,
    chains: std.ArrayList(Chain) = .empty,
    unresolved_calls: u32 = 0,
    external_calls: u32 = 0,
    ambiguous_names: u32 = 0,
    resolved_calls: u32 = 0,
    mutual_call_cycles: u32 = 0,
    findings: std.ArrayList(Finding) = .empty,
    zlint_debt: u32 = 0,
    project_debt: u32 = 0,
    fn_debt: u32 = 0,
    file_debt: u32 = 0,
    structural_debt: u32 = 0,
    debug_debt: u32 = 0,
    cycle_debt: u32 = 0,
    total_debt: u32 = 0,

    pub fn lineOf(src: []const u8, off: u32) u32 {
        var line: u32 = 1;
        for (src[0..off]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    pub fn addFile(self: *Model, path: []const u8, source: []const u8) !u32 {
        const id: u32 = @intCast(self.files.items.len);
        try self.files.append(self.gpa, .{
            .path = path,
            .dir = std.fs.path.dirname(path) orelse ".",
            .source = source,
        });
        try self.file_by_path.put(self.gpa, path, id);
        return id;
    }

    pub fn fileLabel(self: *const Model, file_idx: u32) []const u8 {
        const path = self.files.items[file_idx].path;
        if (std.mem.eql(u8, path, self.root)) return std.fs.path.basename(path);
        if (std.mem.startsWith(u8, path, self.root)) {
            if (path.len > self.root.len and path[self.root.len] == std.fs.path.sep) {
                return path[self.root.len + 1 ..];
            }
        }
        return path;
    }

    pub fn fileIndexByPath(self: *const Model, path: []const u8) ?u32 {
        if (self.file_by_path.get(path)) |file_idx| return file_idx;
        const resolved = std.fs.path.resolve(self.gpa, &.{ self.root, path }) catch return null;
        return self.file_by_path.get(resolved);
    }

    pub fn findingWeight(self: *const Model, rule_id: []const u8, severity: Severity) u32 {
        if (self.config.rule_weights.get(rule_id)) |weight| return weight;
        return switch (severity) {
            .@"error" => self.config.default_error_weight,
            .warning => self.config.default_warning_weight,
            .note => self.config.default_note_weight,
        };
    }

    pub fn fnLabel(self: *const Model, fn_idx: u32) []const u8 {
        const f = self.fns.items[fn_idx];
        return std.fmt.allocPrint(self.gpa, "{s}:{d} {s}", .{
            self.fileLabel(f.file),
            f.line,
            f.name,
        }) catch f.name;
    }

    pub fn resolveImport(self: *Model, from: u32, raw: []const u8) ?u32 {
        const joined = self.resolveImportPath(from, raw) orelse return null;
        return self.file_by_path.get(joined);
    }

    pub fn resolveImportPath(self: *Model, from: u32, raw: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, raw, "std") or
            std.mem.eql(u8, raw, "builtin") or
            std.mem.eql(u8, raw, "root")) return null;
        if (!std.mem.endsWith(u8, raw, ".zig")) return null;
        const f = self.files.items[from];
        return std.fs.path.resolve(self.gpa, &.{ f.dir, raw }) catch null;
    }

    pub fn isExternalImport(raw: []const u8) bool {
        return std.mem.eql(u8, raw, "std") or
            std.mem.eql(u8, raw, "builtin") or
            std.mem.eql(u8, raw, "root");
    }
};

pub fn countOccurrences(haystack: []const u8, needle: []const u8) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |found| {
        n += 1;
        i = found + needle.len;
    }
    return n;
}

pub fn spanStart(ast: *const Ast, node: Ast.Node.Index) u32 {
    return ast.tokenStart(ast.firstToken(node));
}

pub fn spanEnd(ast: *const Ast, node: Ast.Node.Index) u32 {
    const last = ast.lastToken(node);
    return ast.tokenStart(last) + @as(u32, @intCast(ast.tokenSlice(last).len));
}

pub fn tokenTextRange(ast: *const Ast, node: Ast.Node.Index, src: []const u8) []const u8 {
    return src[spanStart(ast, node)..spanEnd(ast, node)];
}

/// Simple glob matcher used by zigdepends.json and --exclude. `*` and `**`
/// both match across path separators, which is convenient for config rules.
pub fn pathMatches(pattern_raw: []const u8, path_raw: []const u8) bool {
    const pattern = stripDotSlash(pattern_raw);
    const path = stripDotSlash(path_raw);
    if (std.mem.indexOfAny(u8, pattern, "*?") == null) {
        if (std.mem.eql(u8, pattern, path)) return true;
        if (path.len > pattern.len and
            std.mem.startsWith(u8, path, pattern) and
            path[pattern.len] == '/') return true;
        return false;
    }
    return globMatch(pattern, path);
}

fn stripDotSlash(s: []const u8) []const u8 {
    var out = s;
    while (std.mem.startsWith(u8, out, "./")) out = out[2..];
    return out;
}

fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var star_text: usize = 0;

    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == text[t] or pattern[p] == '?')) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_text = t;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_text += 1;
            t = star_text;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

test "path matching" {
    try std.testing.expect(pathMatches("src/proto_gen", "src/proto_gen/a.zig"));
    try std.testing.expect(pathMatches("src/proto_gen/**", "src/proto_gen/a/b.zig"));
    try std.testing.expect(pathMatches("**/*_gen.zig", "customworkflows/a_gen.zig"));
    try std.testing.expect(!pathMatches("src/generated", "src/generated.zig"));
}

test "lineOf and countOccurrences" {
    const src = "a\nb\nc";
    try std.testing.expectEqual(@as(u32, 1), Model.lineOf(src, 0));
    try std.testing.expectEqual(@as(u32, 2), Model.lineOf(src, 2));
    try std.testing.expectEqual(@as(u32, 3), Model.lineOf(src, 4));
    try std.testing.expectEqual(@as(u32, 2), countOccurrences("TODO x TODO", "TODO"));
    try std.testing.expectEqual(@as(u32, 0), countOccurrences("nothing", "TODO"));
}
