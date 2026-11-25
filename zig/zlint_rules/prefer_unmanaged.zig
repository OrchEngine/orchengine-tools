//! ## What This Rule Does
//!
//! Flags managed hash-map constructors. A managed map stores an allocator
//! inside the value; the unmanaged variant takes the allocator per operation,
//! so the capability stays with the caller and the value stays plain data.
//!
//! Managed hash maps are not deprecated in Zig 0.17.1. This is a style rule
//! about where the capability lives, not a deprecation rule; use
//! `no-deprecated` for renamed APIs.
//!
//! ### Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const Users = std.StringHashMap(User);
//! const Scores = std.AutoHashMap(u64, i32);
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const Users = std.StringHashMapUnmanaged(User);
//! const Scores = std.AutoHashMapUnmanaged(u64, i32);
//! ```
//!
//! ### Limitations
//!
//! ZLint has no type checker. The rule resolves `std` and module aliases such
//! as `const hm = std.hash_map;`, but a type alias such as
//! `const Map = std.StringHashMap;` is not detected. Use
//! `// zlint-disable-line prefer-unmanaged -- reason` for a deliberate
//! exception.

const std = @import("std");
const mem = std.mem;
const zlint = @import("zlint");

const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const Node = Ast.Node;
const LinterContext = zlint.linter.lint_context;
const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const ast_utils = zlint.linter.ast_utils;

const PreferUnmanaged = @This();

pub const meta: Rule.Meta = .{
    .name = "prefer-unmanaged",
    .category = .style,
    .default = .off,
};

/// Managed constructor names to permit, for a deliberate exception.
allow: []const []const u8 = &.{},

/// Skip declarations inside `test` blocks.
allow_tests: bool = true,

const Container = struct {
    managed: []const u8,
    unmanaged: []const u8,
};

const containers = [_]Container{
    .{ .managed = "HashMap", .unmanaged = "HashMapUnmanaged" },
    .{ .managed = "StringHashMap", .unmanaged = "StringHashMapUnmanaged" },
    .{ .managed = "AutoHashMap", .unmanaged = "AutoHashMapUnmanaged" },
};

pub fn rule(self: *PreferUnmanaged) Rule {
    return Rule.init(self);
}

pub fn runOnNode(self: *const PreferUnmanaged, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .field_access) return;
    if (self.allow_tests and zlint.linter.ast_utils.isInTest(ctx, wrapper.idx)) return;

    const data = ctx.ast().nodeData(wrapper.idx).node_and_token;
    const name = ctx.semantic.tokenSlice(data[1]);
    for (containers) |container| {
        if (!mem.eql(u8, name, container.managed)) continue;
        if (!resolvesToStdNamespace(ctx, data[0], "hash_map")) return;
        if (isAllowed(self, container.managed)) return;

        ctx.report(ctx.diagnosticf(
            "`{s}` stores its allocator; use `std.{s}` and pass the allocator to each call",
            .{ container.managed, container.unmanaged },
            .{ctx.spanT(data[1])},
        ));
        return;
    }
}

fn isAllowed(self: *const PreferUnmanaged, name: []const u8) bool {
    for (self.allow) |allowed| {
        if (mem.eql(u8, allowed, name)) return true;
    }
    return false;
}

const Chain = struct {
    segments: [8][]const u8 = undefined,
    len: usize = 0,
    leftmost: Node.Index = .root,
};

fn getChain(ctx: *LinterContext, node: Node.Index) ?Chain {
    const ast = ctx.ast();
    var chain: Chain = .{ .leftmost = .root };
    var current = node;
    while (true) {
        switch (ast.nodeTag(current)) {
            .field_access => {
                if (chain.len == chain.segments.len) return null;
                const data = ast.nodeData(current).node_and_token;
                chain.segments[chain.len] = ctx.semantic.tokenSlice(data[1]);
                chain.len += 1;
                current = data[0];
            },
            .identifier => {
                if (chain.len == chain.segments.len) return null;
                chain.segments[chain.len] = ctx.semantic.tokenSlice(ast.nodeMainToken(current));
                chain.len += 1;
                chain.leftmost = current;
                break;
            },
            else => return null,
        }
    }
    mem.reverse([]const u8, chain.segments[0..chain.len]);
    return chain;
}

/// Resolves `std.X`, `std.hash_map.X`, and the same paths through a module
/// alias, then accepts an empty tail (top-level re-export) or exactly the
/// namespace the constructor lives in.
fn resolvesToStdNamespace(ctx: *LinterContext, node: Node.Index, namespace: []const u8) bool {
    const chain = getChain(ctx, node) orelse return false;
    if (mem.eql(u8, chain.segments[0], "std")) {
        return tailMatches(chain.segments[1..chain.len], namespace);
    }

    const init = ast_utils.resolveConstAlias(ctx, chain.leftmost) orelse return false;
    const target = getChain(ctx, init) orelse return false;
    if (!mem.eql(u8, target.segments[0], "std")) return false;

    var tail: [8][]const u8 = undefined;
    var len: usize = 0;
    for (target.segments[1..target.len]) |segment| {
        tail[len] = segment;
        len += 1;
    }
    for (chain.segments[1..chain.len]) |segment| {
        tail[len] = segment;
        len += 1;
    }
    return tailMatches(tail[0..len], namespace);
}

fn tailMatches(tail: []const []const u8, namespace: []const u8) bool {
    if (tail.len == 0) return true;
    if (tail.len != 1) return false;
    return mem.eql(u8, tail[0], namespace);
}

const support = @import("tests/prefer_unmanaged_support.zig");

test PreferUnmanaged {
    const t = std.testing;
    var rule_impl = PreferUnmanaged{};
    const rule_value = rule_impl.rule();

    const pass = &[_][:0]const u8{
        // Unmanaged is the target.
        \\const std = @import("std");
        \\const Map = std.StringHashMapUnmanaged(u32);
        \\
        ,
        // A different namespace is not ours to judge.
        \\const other = struct {
        \\    pub fn StringHashMap(comptime T: type) type { return T; }
        \\};
        \\const Map = other.StringHashMap(u32);
        \\
        ,
        // Unrelated std containers are untouched.
        \\const std = @import("std");
        \\const List = std.ArrayList(u32);
        \\
        ,
        // Tests are skipped by default.
        \\const std = @import("std");
        \\test "map" { _ = std.StringHashMap(u32); }
        \\
        ,
    };
    for (pass) |source| try support.expectPass(t.allocator, rule_value, source);

    const fail = &[_]struct { source: [:0]const u8, count: usize }{
        .{
            .source =
            \\const std = @import("std");
            \\const Map = std.StringHashMap(u32);
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const Scores = std.AutoHashMap(u32, u32);
            \\const Users = std.StringHashMap(u32);
            \\
            ,
            .count = 2,
        },
        .{
            // Module alias.
            .source =
            \\const std = @import("std");
            \\const hm = std.hash_map;
            \\const Map = hm.StringHashMap(u32);
            \\
            ,
            .count = 1,
        },
        .{
            // Alias to std itself.
            .source =
            \\const std = @import("std");
            \\const s = std;
            \\const Map = s.StringHashMap(u32);
            \\
            ,
            .count = 1,
        },
        .{
            // Fully-qualified path.
            .source =
            \\const std = @import("std");
            \\const Map = std.hash_map.StringHashMap(u32);
            \\
            ,
            .count = 1,
        },
    };
    for (fail) |case| try support.expectFailCount(t.allocator, rule_value, case.source, case.count);

    // The allow list permits a deliberate exception.
    var allowed_impl = PreferUnmanaged{ .allow = &.{"StringHashMap"} };
    const allowed_rule = allowed_impl.rule();
    try support.expectPass(t.allocator, allowed_rule,
        \\const std = @import("std");
        \\const Map = std.StringHashMap(u32);
        \\
    );
}
