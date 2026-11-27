//! ## What This Rule Does
//!
//! Disallows `std.heap.ArenaAllocator` inside `test` blocks and in test-only
//! helpers backed by `std.testing.allocator`.
//!
//! ## Rule Details
//!
//! An `ArenaAllocator` in a test absorbs memory leaks and turns double frees
//! into no-ops, preventing `std.testing.allocator` from catching ownership and
//! cleanup bugs in the code under test.
//!
//! This rule flags:
//! - Any reference to `std.heap.ArenaAllocator` (including local `const` aliases)
//!   inside a `test` block.
//! - Any `ArenaAllocator.init(std.testing.allocator)` call (including aliased
//!   `testing.allocator`) or struct field default `.init(std.testing.allocator)`
//!   on an `ArenaAllocator` field outside a `test` block.
//!
//! Production `ArenaAllocator` scopes (such as `self.allocator`, `gpa`, or
//! `context.gpa`) are not flagged.
//!
//! Off by default; enabled by `zlint.json`.

const std = @import("std");
const mem = std.mem;
const zlint = @import("zlint");

const Ast = zlint.Semantic.Ast;
const Node = Ast.Node;
const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const LinterContext = zlint.linter.lint_context;
const ast_utils = zlint.linter.ast_utils;

const NoTestArena = @This();

allow_paths: []const []const u8 = &[_][]const u8{},

pub const meta: Rule.Meta = .{
    .name = "no-test-arena",
    .category = .restriction,
    .default = .off,
};

pub fn runOnNode(self: *const NoTestArena, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const pathname = ctx.source.pathname orelse "";
    for (self.allow_paths) |allowed| {
        if (mem.endsWith(u8, pathname, allowed)) return;
    }

    const ast = ctx.ast();
    if (ast_utils.isInTest(ctx, wrapper.idx)) {
        switch (wrapper.node.tag) {
            .field_access, .identifier => {
                if (isArenaAllocatorType(ctx, wrapper.idx)) {
                    ctx.report(ctx.diagnostic(
                        "`ArenaAllocator` is not allowed in tests; use `std.testing.allocator` directly",
                        .{ctx.spanN(wrapper.idx)},
                    ));
                }
            },
            else => {},
        }
        return;
    }

    switch (wrapper.node.tag) {
        .container_field_init, .container_field_align, .container_field => {
            const field = ast.fullContainerField(wrapper.idx) orelse return;
            const type_expr = field.ast.type_expr.unwrap() orelse return;
            const value_expr = field.ast.value_expr.unwrap() orelse return;
            if (!isArenaAllocatorType(ctx, type_expr)) return;
            if (isTestingInitCall(ctx, value_expr, true)) {
                ctx.report(ctx.diagnostic(
                    "test-backed `ArenaAllocator` is not allowed; use `std.testing.allocator` directly",
                    .{ctx.spanN(value_expr)},
                ));
            }
        },
        .call, .call_comma, .call_one, .call_one_comma => {
            if (isTestingInitCall(ctx, wrapper.idx, false)) {
                ctx.report(ctx.diagnostic(
                    "test-backed `ArenaAllocator` is not allowed; use `std.testing.allocator` directly",
                    .{ctx.spanN(wrapper.idx)},
                ));
            }
        },
        else => {},
    }
}

fn isArenaAllocatorType(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    var curr = node;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                const base, const field_tok = ast.nodeData(curr).node_and_token;
                if (!mem.eql(u8, ctx.semantic.tokenSlice(field_tok), "ArenaAllocator")) return false;
                return isStdHeap(ctx, base);
            },
            .identifier => {
                curr = ast_utils.resolveConstAlias(ctx, curr) orelse return false;
            },
            else => return false,
        }
    }
    return false;
}

fn isStdHeap(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    var curr = node;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                const base, const field_tok = ast.nodeData(curr).node_and_token;
                if (!mem.eql(u8, ctx.semantic.tokenSlice(field_tok), "heap")) return false;
                return isStd(ctx, base);
            },
            .identifier => {
                curr = ast_utils.resolveConstAlias(ctx, curr) orelse return false;
            },
            else => return false,
        }
    }
    return false;
}

fn isStdTesting(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    var curr = node;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                const base, const field_tok = ast.nodeData(curr).node_and_token;
                if (!mem.eql(u8, ctx.semantic.tokenSlice(field_tok), "testing")) return false;
                return isStd(ctx, base);
            },
            .identifier => {
                curr = ast_utils.resolveConstAlias(ctx, curr) orelse return false;
            },
            else => return false,
        }
    }
    return false;
}

fn isStd(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    var curr = node;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        switch (ast.nodeTag(curr)) {
            .identifier => {
                if (mem.eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(curr)), "std")) return true;
                curr = ast_utils.resolveConstAlias(ctx, curr) orelse return false;
            },
            .builtin_call, .builtin_call_comma, .builtin_call_two, .builtin_call_two_comma => {
                const name = ast.tokenSlice(ast.nodeMainToken(curr));
                return mem.eql(u8, name, "@import");
            },
            else => return false,
        }
    }
    return false;
}

fn isTestingAllocator(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    var curr = node;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                const base, const field_tok = ast.nodeData(curr).node_and_token;
                if (!mem.eql(u8, ctx.semantic.tokenSlice(field_tok), "allocator")) return false;
                return isStdTesting(ctx, base);
            },
            .identifier => {
                curr = ast_utils.resolveConstAlias(ctx, curr) orelse return false;
            },
            else => return false,
        }
    }
    return false;
}

fn isTestingInitCall(ctx: *LinterContext, node: Node.Index, allow_enum_literal: bool) bool {
    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;
    const call = ast.fullCall(&buf, node) orelse return false;
    if (call.ast.params.len != 1) return false;
    if (!isTestingAllocator(ctx, call.ast.params[0])) return false;

    const callee = call.ast.fn_expr;
    switch (ast.nodeTag(callee)) {
        .enum_literal => {
            if (!allow_enum_literal) return false;
            const tok = ast.nodeMainToken(callee);
            return mem.eql(u8, ctx.semantic.tokenSlice(tok), "init");
        },
        .field_access => {
            const base, const field_tok = ast.nodeData(callee).node_and_token;
            if (!mem.eql(u8, ctx.semantic.tokenSlice(field_tok), "init")) return false;
            return isArenaAllocatorType(ctx, base);
        },
        else => return false,
    }
}

pub fn rule(self: *NoTestArena) Rule {
    return Rule.init(self);
}

const support = @import("tests/no_test_arena_support.zig");

test NoTestArena {
    const t = std.testing;
    var rule_impl = NoTestArena{};
    const rule_value = rule_impl.rule();

    const pass = &[_][:0]const u8{
        // Production ArenaAllocator is allowed.
        \\const std = @import("std");
        \\fn run(gpa: std.mem.Allocator) void {
        \\    var arena = std.heap.ArenaAllocator.init(gpa);
        \\    defer arena.deinit();
        \\}
        \\
        ,
        // Normal testing.allocator without ArenaAllocator is allowed.
        \\const std = @import("std");
        \\test "direct" {
        \\    const buf = try std.testing.allocator.alloc(u8, 4);
        \\    defer std.testing.allocator.free(buf);
        \\}
        \\
        ,
        // Struct field with non-testing allocator default is allowed.
        \\const std = @import("std");
        \\const Holder = struct {
        \\    arena: std.heap.ArenaAllocator,
        \\};
        \\
        ,
    };

    for (pass) |source| {
        try support.expectPass(t.allocator, rule_value, source);
    }

    const fail = &[_]struct {
        source: [:0]const u8,
        count: usize,
    }{
        .{
            // Direct std.heap.ArenaAllocator in test.
            .source =
            \\const std = @import("std");
            \\test "arena" {
            \\    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            \\    defer arena.deinit();
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            // Aliased ArenaAllocator used in test.
            .source =
            \\const std = @import("std");
            \\const Arena = std.heap.ArenaAllocator;
            \\test "aliased arena" {
            \\    var arena = Arena.init(std.testing.allocator);
            \\    defer arena.deinit();
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            // Aliased heap used in test.
            .source =
            \\const std = @import("std");
            \\const heap = std.heap;
            \\test "aliased heap" {
            \\    var arena = heap.ArenaAllocator.init(std.testing.allocator);
            \\    defer arena.deinit();
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            // Test helper struct field default backed by std.testing.allocator.
            .source =
            \\const std = @import("std");
            \\const TestProcess = struct {
            \\    arena: std.heap.ArenaAllocator = .init(std.testing.allocator),
            \\};
            \\
            ,
            .count = 1,
        },
        .{
            // Test helper function backed by aliased testing.allocator.
            .source =
            \\const std = @import("std");
            \\const testing = std.testing;
            \\fn makeArena() std.heap.ArenaAllocator {
            \\    return std.heap.ArenaAllocator.init(testing.allocator);
            \\}
            \\
            ,
            .count = 1,
        },
    };

    for (fail) |case| {
        try support.expectFailCount(t.allocator, rule_value, case.source, case.count);
    }
}
