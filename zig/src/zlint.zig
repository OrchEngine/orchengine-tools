const std = @import("std");
const mem = std.mem;
const model = @import("model.zig");

const Model = model.Model;

pub fn load(model_ptr: *Model, io: std.Io, path: []const u8) !void {
    const gpa = model_ptr.gpa;
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    );

    var lines = mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try parseLine(model_ptr, trimmed);
    }
}

pub fn parseLine(model_ptr: *Model, line: []const u8) !void {
    const gpa = model_ptr.gpa;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, gpa, line, .{});
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidZlintReport,
    };

    const rule_id = stringOf(obj.get("code")) orelse "zlint";
    const message = stringOf(obj.get("message")) orelse "";
    const source_name = stringOf(obj.get("source_name")) orelse "";
    const severity = parseSeverity(obj.get("level"));
    const span = findSpan(obj.get("labels"));

    try model_ptr.findings.append(gpa, .{
        .rule_id = rule_id,
        .severity = severity,
        .message = message,
        .path = source_name,
        .line = span.start,
        .end_line = span.end,
        .source = .zlint,
        .weight = model_ptr.findingWeight(rule_id, severity),
    });
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn parseSeverity(value: ?std.json.Value) model.Severity {
    const s = stringOf(value) orelse return .warning;
    if (mem.eql(u8, s, "error")) return .@"error";
    if (mem.eql(u8, s, "note")) return .note;
    return .warning;
}

const Span = struct {
    start: u32 = 0,
    end: u32 = 0,
};

fn findSpan(value: ?std.json.Value) Span {
    const v = value orelse return .{};
    const array = switch (v) {
        .array => |a| a,
        else => return .{},
    };

    var fallback: Span = .{};
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const span = Span{
            .start = lineOf(obj.get("start")),
            .end = lineOf(obj.get("end")),
        };
        if (span.start == 0 and span.end == 0) continue;
        if (isPrimary(obj.get("primary"))) return span;
        if (fallback.start == 0 and fallback.end == 0) fallback = span;
    }
    return fallback;
}

fn lineOf(value: ?std.json.Value) u32 {
    const v = value orelse return 0;
    const obj = switch (v) {
        .object => |o| o,
        else => return 0,
    };
    const line = obj.get("line") orelse return 0;
    return switch (line) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else 0,
        else => 0,
    };
}

fn isPrimary(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return switch (v) {
        .bool => |b| b,
        else => false,
    };
}

test "parse zlint warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Model{
        .gpa = arena.allocator(),
        .root = ".",
        .title = "test",
        .settings = .{},
    };

    try parseLine(&m,
        \\{"level":"warning","message":"too many imports","code":"max-file-imports","labels":[{"start":{"line":12,"column":1},"end":{"line":12,"column":2},"primary":true,"label":null}],"source_name":"src/a.zig","help":null}
    );

    try std.testing.expectEqual(@as(usize, 1), m.findings.items.len);
    const finding = m.findings.items[0];
    try std.testing.expectEqualStrings("max-file-imports", finding.rule_id);
    try std.testing.expectEqual(model.Severity.warning, finding.severity);
    try std.testing.expectEqualStrings("src/a.zig", finding.path);
    try std.testing.expectEqual(@as(u32, 12), finding.line);
    try std.testing.expectEqual(@as(u32, 1), finding.weight);
}

test "parse zlint error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = Model{
        .gpa = arena.allocator(),
        .root = ".",
        .title = "test",
        .settings = .{},
    };

    try parseLine(&m,
        \\{"level":"error","message":"bad cast","code":"forbid-casts","labels":[{"start":{"line":3,"column":5},"end":{"line":3,"column":12},"primary":false,"label":null}],"source_name":"src/a.zig","help":null}
    );

    try std.testing.expectEqual(@as(usize, 1), m.findings.items.len);
    const finding = m.findings.items[0];
    try std.testing.expectEqual(model.Severity.@"error", finding.severity);
    try std.testing.expectEqual(@as(u32, 3), finding.line);
    try std.testing.expectEqual(@as(u32, 10), finding.weight);
}
