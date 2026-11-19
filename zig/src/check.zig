const std = @import("std");
const model = @import("model.zig");

const Model = model.Model;

pub const Format = enum {
    text,
    json,
};

pub fn print(model_ptr: *Model, io: std.Io, format: Format) !bool {
    var aw = std.Io.Writer.Allocating.init(model_ptr.gpa);
    defer aw.deinit();
    const failed = try write(model_ptr, &aw.writer, format);
    try std.Io.File.writeStreamingAll(.stdout(), io, aw.written());
    return failed;
}

pub fn write(model_ptr: *Model, w: *std.Io.Writer, format: Format) !bool {
    var failed = false;
    for (model_ptr.findings.items) |finding| {
        if (!finding.suppressed and finding.severity == .@"error") failed = true;
    }

    switch (format) {
        .text => try writeText(model_ptr, w),
        .json => try writeJson(model_ptr, w),
    }
    return failed;
}

fn writeText(model_ptr: *Model, w: *std.Io.Writer) !void {
    for (model_ptr.findings.items) |finding| {
        const path = if (finding.path.len == 0) "?" else finding.path;
        try w.print("{s}:{d}: {s} [{s}] {s}", .{
            path,
            finding.line,
            @tagName(finding.severity),
            finding.rule_id,
            finding.message,
        });
        if (finding.suppressed) {
            if (finding.suppression_reason) |reason| {
                try w.print(" (suppressed: {s})", .{reason});
            } else {
                try w.writeAll(" (suppressed)");
            }
        }
        try w.writeAll("\n");
    }
}

fn writeJson(model_ptr: *Model, w: *std.Io.Writer) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginArray();
    for (model_ptr.findings.items) |finding| {
        try s.beginObject();
        try s.objectField("rule_id");
        try s.write(finding.rule_id);
        try s.objectField("severity");
        try s.write(@tagName(finding.severity));
        try s.objectField("message");
        try s.write(finding.message);
        try s.objectField("path");
        try s.write(finding.path);
        try s.objectField("line");
        try s.write(finding.line);
        try s.objectField("end_line");
        try s.write(finding.end_line);
        try s.objectField("source");
        try s.write(@tagName(finding.source));
        try s.objectField("weight");
        try s.write(finding.weight);
        try s.objectField("suppressed");
        try s.write(finding.suppressed);
        if (finding.suppression_reason) |reason| {
            try s.objectField("suppression_reason");
            try s.write(reason);
        }
        try s.endObject();
    }
    try s.endArray();
    try w.writeAll("\n");
}

fn testModel(alloc: std.mem.Allocator) Model {
    return .{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
}

test "check text output and warning exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());
    try m.findings.append(arena.allocator(), .{
        .rule_id = "test-rule",
        .severity = .warning,
        .message = "msg",
        .path = "a.zig",
        .line = 2,
        .source = .zlint,
        .weight = 1,
    });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const failed = try write(&m, &aw.writer, .text);

    try std.testing.expect(!failed);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "a.zig:2: warning [test-rule] msg") != null);
}

test "check json output and error exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());
    try m.findings.append(arena.allocator(), .{
        .rule_id = "test-rule",
        .severity = .@"error",
        .message = "bad",
        .path = "a.zig",
        .line = 3,
        .source = .project,
        .weight = 10,
    });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const failed = try write(&m, &aw.writer, .json);

    try std.testing.expect(failed);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"rule_id\":\"test-rule\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"severity\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"source\":\"project\"") != null);
}

test "suppressed errors do not fail check" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());
    try m.findings.append(arena.allocator(), .{
        .rule_id = "test-rule",
        .severity = .@"error",
        .message = "bad",
        .path = "a.zig",
        .line = 3,
        .source = .project,
        .weight = 10,
        .suppressed = true,
        .suppression_reason = "accepted",
    });

    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const failed = try write(&m, &aw.writer, .text);

    try std.testing.expect(!failed);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "suppressed: accepted") != null);
}
