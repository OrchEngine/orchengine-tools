//! ## What This Rule Does
//!
//! Requires every `deinit` to return `void`, so callers can release a value
//! with `defer` on every path.
//!
//! ## Rule Details
//!
//! A `deinit` that returns an error union cannot be deferred: `defer` has no
//! place to put the error, so every caller either swallows it or hand-writes
//! teardown. Teardown that can fail — flush, commit, fsync, close — belongs in
//! a named method the caller invokes before `deinit`.
//!
//! The rule flags a function named `deinit` whose return type is:
//! - an error union (`!void`, `Allocator.Error!void`), or
//! - anything other than `void`.
//!
//! Test-local declarations are skipped by default.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! pub fn deinit(self: *Sink) !void {
//!     try self.database.commit();
//!     self.database.close();
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! pub fn deinit(self: *Sink) void {
//!     self.database.close();
//! }
//!
//! pub fn finish(self: *Sink) !void {
//!     try self.database.commit();
//! }
//! ```

const std = @import("std");
const zlint = @import("zlint");
const ast_utils = zlint.linter.ast_utils;

const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const LinterContext = zlint.linter.lint_context;

const DeinitReturnsVoid = @This();

/// Skip declarations inside `test` blocks.
allow_tests: bool = true,

pub const meta: Rule.Meta = .{
    .name = "deinit-returns-void",
    .category = .correctness,
    .default = .off,
};

pub fn runOnNode(self: *const DeinitReturnsVoid, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .fn_decl) return;
    if (self.allow_tests and ast_utils.isInTest(ctx, wrapper.idx)) return;

    const ast = ctx.ast();
    var buf: [1]zlint.Semantic.Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, wrapper.idx) orelse return;

    const name_token = proto.name_token orelse return;
    if (!std.mem.eql(u8, ctx.semantic.tokenSlice(name_token), "deinit")) return;

    // No return type is `void`.
    const return_type = proto.ast.return_type.unwrap() orelse return;

    // `!void` parses as return type `void` with a `!` token before it, so the
    // error union is detected from the preceding token, not from the node tag.
    // Follow `const` aliases first, so `Void` and `Fallible` are judged by what
    // they name rather than by the identifier spelling.
    var resolved = return_type;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        if (ast_utils.hasErrorUnion(ast, resolved)) {
            ctx.report(ctx.diagnostic(
                "`deinit` must not fail; move fallible teardown to a named method",
                .{ctx.spanN(return_type)},
            ));
            return;
        }
        if (isVoidLiteral(ast, ctx, resolved)) return;
        resolved = ast_utils.resolveConstAlias(ctx, resolved) orelse break;
    }

    ctx.report(ctx.diagnostic(
        "`deinit` must return `void`",
        .{ctx.spanN(return_type)},
    ));
}

fn isVoidLiteral(ast: *const zlint.Semantic.Ast, ctx: *LinterContext, node: zlint.Semantic.Ast.Node.Index) bool {
    if (ast.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(node)), "void");
}

pub fn rule(self: *DeinitReturnsVoid) Rule {
    return Rule.init(self);
}

const support = @import("tests/deinit_returns_void_support.zig");

test DeinitReturnsVoid {
    const t = std.testing;
    var rule_impl = DeinitReturnsVoid{};
    const rule_value = rule_impl.rule();

    const pass = &[_][:0]const u8{
        // Implicit `void`.
        \\const Sink = struct {
        \\    pub fn deinit(self: *Sink) void { _ = self; }
        \\};
        \\
        ,
        // A fallible method with a name that is not `deinit`.
        \\const Sink = struct {
        \\    pub fn finish(self: *Sink) !void { _ = self; }
        \\};
        \\
        ,
        // A function that merely mentions deinit in its body.
        \\fn release(sink: *Sink) void { sink.deinit(); }
        \\const Sink = struct { pub fn deinit(self: *Sink) void { _ = self; } };
        \\
        ,
        // Test-local declarations are skipped.
        \\test "sink" {
        \\    const Sink = struct {
        \\        pub fn deinit(self: *Sink) !void { _ = self; }
        \\    };
        \\    _ = Sink;
        \\}
        \\
        ,
        // A file-level alias to `void` is still `void`.
        \\const Void = void;
        \\const Sink = struct {
        \\    pub fn deinit(self: *Sink) Void { _ = self; }
        \\};
        \\
        ,
        // A container-level alias to `void` is still `void`.
        \\const Sink = struct {
        \\    const Void = void;
        \\    pub fn deinit(self: *Sink) Void { _ = self; }
        \\};
        \\
        ,
        // Alias of an alias.
        \\const Void = void;
        \\const Nothing = Void;
        \\const Sink = struct {
        \\    pub fn deinit(self: *Sink) Nothing { _ = self; }
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
            // Bare error union.
            .source =
            \\const Sink = struct {
            \\    pub fn deinit(self: *Sink) !void { _ = self; }
            \\};
            \\
            ,
            .count = 1,
        },
        .{
            // Named error set.
            .source =
            \\const Sink = struct {
            \\    pub fn deinit(self: *Sink) error{Commit}!void { _ = self; }
            \\};
            \\
            ,
            .count = 1,
        },
        .{
            // Non-error return type.
            .source =
            \\const Sink = struct {
            \\    pub fn deinit(self: *Sink) u32 { _ = self; return 0; }
            \\};
            \\
            ,
            .count = 1,
        },
        .{
            // Private destructor is still a destructor.
            .source =
            \\const Sink = struct {
            \\    fn deinit(self: *Sink) !void { _ = self; }
            \\};
            \\
            ,
            .count = 1,
        },
        .{
            // Two destructors, two diagnostics.
            .source =
            \\const A = struct { pub fn deinit(self: *A) !void { _ = self; } };
            \\const B = struct { pub fn deinit(self: *B) error{Boom}!void { _ = self; } };
            \\
            ,
            .count = 2,
        },
    };

    for (fail) |case| {
        try support.expectFailCount(t.allocator, rule_value, case.source, case.count);
    }
}
