const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const model = @import("model.zig");

const Model = model.Model;

pub fn load(model_ptr: *Model, io: Io, path: []const u8) !void {
    const source = try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        model_ptr.gpa,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );
    try parse(model_ptr, source);
    try model_ptr.validateProjectConfig();
}

pub fn parse(model_ptr: *Model, source: []const u8) !void {
    const gpa = model_ptr.gpa;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, gpa, source, .{});
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    if (obj.get("exclude")) |value| try appendStrings(gpa, &model_ptr.config.exclude, value);
    if (obj.get("test_roots")) |value| try appendStrings(gpa, &model_ptr.config.test_roots, value);

    if (obj.get("graph")) |graph_value| {
        switch (graph_value) {
            .object => |graph_cfg| {
                if (graph_cfg.get("exclude")) |v| try appendStrings(gpa, &model_ptr.config.graph_exclude, v);
            },
            else => {},
        }
    }

    if (obj.get("generated")) |gen_value| {
        switch (gen_value) {
            .object => |gen| {
                if (gen.get("markers")) |v| try appendStrings(gpa, &model_ptr.config.generated_markers, v);
                if (gen.get("paths")) |v| try appendStrings(gpa, &model_ptr.config.generated_paths, v);
                if (gen.get("include_in_metrics")) |v| {
                    switch (v) {
                        .bool => |b| model_ptr.config.include_generated_metrics = b,
                        .string => |s| model_ptr.config.include_generated_metrics = mem.eql(u8, s, "true"),
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (obj.get("capabilities")) |cap_value| {
        switch (cap_value) {
            .object => |cap| {
                if (cap.get("debug_io")) |v| {
                    switch (v) {
                        .bool => |b| model_ptr.config.debug_io = b,
                        else => {},
                    }
                }
                if (cap.get("track")) |v| {
                    switch (v) {
                        .bool => |b| model_ptr.config.track_capabilities = b,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (obj.get("fields")) |fields_value| {
        switch (fields_value) {
            .object => |fields| {
                if (fields.get("track")) |v| {
                    switch (v) {
                        .bool => |b| model_ptr.config.track_fields = b,
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    if (obj.get("findings")) |findings_value| {
        switch (findings_value) {
            .object => |findings| {
                if (asU32(findings.get("error"))) |n| model_ptr.config.default_error_weight = n;
                if (asU32(findings.get("warning"))) |n| model_ptr.config.default_warning_weight = n;
                if (asU32(findings.get("note"))) |n| model_ptr.config.default_note_weight = n;
            },
            else => {},
        }
    }

    if (obj.get("weights")) |weights_value| {
        switch (weights_value) {
            .object => |weights| {
                var it = weights.iterator();
                while (it.next()) |entry| {
                    if (asU32(entry.value_ptr.*)) |weight| {
                        try model_ptr.config.rule_weights.put(gpa, entry.key_ptr.*, weight);
                    }
                }
            },
            else => {},
        }
    }

    if (obj.get("project_rules")) |rules_value| {
        switch (rules_value) {
            .object => |rules| {
                var it = rules.iterator();
                while (it.next()) |entry| {
                    const severity = severityOf(entry.value_ptr.*) orelse return error.InvalidSeverity;
                    try model_ptr.config.project_rule_severities.put(gpa, entry.key_ptr.*, severity);
                }
            },
            else => {},
        }
    }

    if (obj.get("suppressions")) |suppressions_value| {
        switch (suppressions_value) {
            .array => |items| {
                for (items.items) |item| {
                    const entry = switch (item) {
                        .object => |o| o,
                        else => continue,
                    };
                    try model_ptr.config.suppressions.append(gpa, .{
                        .rule_id = stringOf(entry.get("rule")) orelse "",
                        .key = stringOf(entry.get("key")) orelse "",
                        .reason = stringOf(entry.get("reason")) orelse "",
                    });
                }
            },
            else => {},
        }
    }
}

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn severityOf(value: std.json.Value) ?model.Severity {
    const s = switch (value) {
        .string => |text| text,
        else => return null,
    };
    if (mem.eql(u8, s, "error")) return .@"error";
    if (mem.eql(u8, s, "warning") or mem.eql(u8, s, "warn")) return .warning;
    if (mem.eql(u8, s, "note") or mem.eql(u8, s, "info")) return .note;
    return null;
}

fn appendStrings(gpa: model.Gpa, list: *std.ArrayList([]const u8), value: std.json.Value) !void {
    switch (value) {
        .array => |arr| {
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| try list.append(gpa, s),
                    else => {},
                }
            }
        },
        .string => |s| try list.append(gpa, s),
        else => {},
    }
}

fn asU32(value: ?std.json.Value) ?u32 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |n| if (n >= 0 and n <= std.math.maxInt(u32)) @intCast(n) else null,
        .float => |f| if (f >= 0 and f <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) @intFromFloat(f) else null,
        else => null,
    };
}

fn testModel(alloc: Allocator) Model {
    return .{
        .gpa = alloc,
        .root = ".",
        .title = "test",
        .settings = .{},
    };
}

test "parse project rules and suppressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m,
        \\{"project_rules":{"import-cycle":"error","call-cycle":"warning"},"suppressions":[{"rule":"import-cycle","key":"a.zig,b.zig","reason":"legacy"}]}
    );
    try m.validateProjectConfig();

    try std.testing.expectEqual(model.Severity.@"error", m.projectSeverity("import-cycle"));
    try std.testing.expectEqual(model.Severity.warning, m.projectSeverity("call-cycle"));
    try std.testing.expectEqual(@as(usize, 1), m.config.suppressions.items.len);
    try std.testing.expectEqualStrings("a.zig,b.zig", m.config.suppressions.items[0].key);
}

test "reject unknown project rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m, "{\"project_rules\":{\"not-a-rule\":\"error\"}}");
    try std.testing.expectError(error.UnknownProjectRule, m.validateProjectConfig());
}

test "reject suppression without reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m, "{\"suppressions\":[{\"rule\":\"import-cycle\",\"key\":\"a.zig\"}]}");
    try std.testing.expectError(error.MissingSuppressionReason, m.validateProjectConfig());
}

test "reject suppression without key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m, "{\"suppressions\":[{\"rule\":\"import-cycle\",\"reason\":\"legacy\"}]}");
    try std.testing.expectError(error.MissingSuppressionKey, m.validateProjectConfig());
}

test "reject invalid project severity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try std.testing.expectError(error.InvalidSeverity, parse(&m, "{\"project_rules\":{\"import-cycle\":\"loud\"}}"));
}

test "parse test roots and test-only severity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m,
        \\{"test_roots":["src/unit_tests.zig","customworkflows/generated.zig"],"project_rules":{"test-only-import":"error"}}
    );
    try m.validateProjectConfig();

    try std.testing.expectEqual(@as(usize, 2), m.config.test_roots.items.len);
    try std.testing.expectEqualStrings("src/unit_tests.zig", m.config.test_roots.items[0]);
    try std.testing.expectEqual(model.Severity.@"error", m.projectSeverity("test-only-import"));
}

test "parse graph exclusions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var m = testModel(arena.allocator());

    try parse(&m,
        \\{"graph":{"exclude":["src/unit_tests.zig","src/integration_tests.zig"]}}
    );

    try std.testing.expectEqual(@as(usize, 2), m.config.graph_exclude.items.len);
    try std.testing.expect(m.graphExcludes("src/unit_tests.zig"));
    try std.testing.expect(m.graphExcludes("src/integration_tests.zig"));
    try std.testing.expect(!m.graphExcludes("src/main.zig"));
}
