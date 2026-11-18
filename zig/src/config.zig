const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");

const Model = model.Model;

pub fn load(model_ptr: *Model, io: Io, path: []const u8) !void {
    const gpa = model_ptr.gpa;
    const source = try Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );

    const root = try std.json.parseFromSliceLeaky(std.json.Value, gpa, source, .{});
    const obj = switch (root) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };

    if (obj.get("exclude")) |value| try appendStrings(gpa, &model_ptr.config.exclude, value);

    if (obj.get("generated")) |gen_value| {
        switch (gen_value) {
            .object => |gen| {
                if (gen.get("markers")) |v| try appendStrings(gpa, &model_ptr.config.generated_markers, v);
                if (gen.get("paths")) |v| try appendStrings(gpa, &model_ptr.config.generated_paths, v);
                if (gen.get("include_in_metrics")) |v| {
                    switch (v) {
                        .bool => |b| model_ptr.config.include_generated_metrics = b,
                        .string => |s| model_ptr.config.include_generated_metrics = std.mem.eql(u8, s, "true"),
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

    if (obj.get("rules")) |rules_value| {
        switch (rules_value) {
            .object => |rules| {
                if (asU32(rules.get("loc"))) |n| model_ptr.settings.loc_threshold = n;
                if (asU32(rules.get("complexity"))) |n| model_ptr.settings.cx_threshold = n;
                if (asU32(rules.get("nesting"))) |n| model_ptr.settings.nest_threshold = n;
                if (asU32(rules.get("params"))) |n| model_ptr.settings.param_threshold = n;
                if (asU32(rules.get("debug_output"))) |n| model_ptr.settings.debug_output_weight = n;
            },
            else => {},
        }
    }
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
