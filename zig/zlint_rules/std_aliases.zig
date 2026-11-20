//! ## What This Rule Does
//! Enforces the canonical aliases for `std.mem` and `std.mem.Allocator`.
//!
//! Files that use `std.mem` should import it as `mem` and reference the alias
//! instead of spelling out `std.mem` at every call site. Files that use
//! `std.mem.Allocator` should import it as `Allocator`, derived from the `mem`
//! alias.
//!
//! The canonical header is:
//! ```zig
//! const std = @import("std");
//! const mem = std.mem;
//! const Allocator = mem.Allocator;
//! ```
//!
//! The alias declarations themselves are not reported. References to a
//! different `mem` namespace (for example a struct field or parameter named
//! `mem`) are ignored.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn eql(a: []const u8, b: []const u8) bool {
//!   return std.mem.eql(u8, a, b);
//! }
//!
//! fn allocatorCopy(allocator: std.mem.Allocator) ![]u8 {
//!   return allocator.dupe(u8, "x");
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//! const mem = std.mem;
//! const Allocator = mem.Allocator;
//!
//! fn eql(a: []const u8, b: []const u8) bool {
//!   return mem.eql(u8, a, b);
//! }
//!
//! fn allocatorCopy(allocator: Allocator) ![]u8 {
//!   return allocator.dupe(u8, "x");
//! }
//! ```

const std = @import("std");
const zlint = @import("zlint");

const Semantic = zlint.Semantic;
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const LinterContext = zlint.linter.lint_context;
const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const ast_utils = zlint.linter.ast_utils;
const Error = zlint.Error;

const StdAliases = @This();
pub const meta: Rule.Meta = .{
    .name = "std-aliases",
    .category = .style,
    .default = .off,
};

const Chain = struct {
    /// The original chain node.
    node: Node.Index,
    /// The left-most identifier node.
    leftmost: Node.Index,
    /// Identifiers in source order.
    segments: [8][]const u8 = undefined,
    /// Token of each identifier in `segments`.
    tokens: [8]TokenIndex = undefined,
    len: usize = 0,

    fn startsWith(self: Chain, prefix: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.segments[0], prefix);
    }
};

/// Split a field access chain into its identifiers.
///
/// `foo.bar.baz` -> `{ "foo", "bar", "baz" }`
fn getChain(ctx: *LinterContext, node: Node.Index) ?Chain {
    const ast = ctx.ast();
    var chain: Chain = .{ .node = node, .leftmost = .root };
    var curr = node;

    while (true) {
        switch (ast.nodeTag(curr)) {
            .field_access => {
                if (chain.len == chain.segments.len) return null;
                const data = ast.nodeData(curr).node_and_token;
                const token: TokenIndex = data[1];
                chain.segments[chain.len] = ctx.semantic.tokenSlice(token);
                chain.tokens[chain.len] = token;
                chain.len += 1;
                curr = data[0];
            },
            .identifier => {
                if (chain.len == chain.segments.len) return null;
                const token = ast.nodeMainToken(curr);
                chain.segments[chain.len] = ctx.semantic.tokenSlice(token);
                chain.tokens[chain.len] = token;
                chain.len += 1;
                chain.leftmost = curr;
                break;
            },
            else => return null,
        }
    }

    std.mem.reverse([]const u8, chain.segments[0..chain.len]);
    std.mem.reverse(TokenIndex, chain.tokens[0..chain.len]);
    return chain;
}

/// Check whether `node` is the initializer of a declaration named `name`.
///
/// This exempts `const mem = std.mem;` and `const Allocator = mem.Allocator;`.
fn isDeclInit(ctx: *LinterContext, node: Node.Index, name: []const u8) bool {
    var parents = ctx.links().iterParentIds(node);
    while (parents.next()) |parent| {
        if (parent == node) continue;

        const var_decl = ctx.ast().fullVarDecl(parent) orelse continue;
        const init = var_decl.ast.init_node.unwrap() orelse continue;
        if (init != node) continue;

        const name_token = var_decl.ast.mut_token + 1;
        return std.mem.eql(u8, name, ctx.semantic.tokenSlice(name_token));
    }
    return false;
}

/// Check for a top-level alias declaration whose initializer is exactly
/// `expected`.
fn hasTopLevelAlias(ctx: *LinterContext, name: []const u8, expected: []const u8) bool {
    const ast = ctx.ast();
    for (ast.rootDecls()) |decl| {
        const var_decl = ast.fullVarDecl(decl) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, name, ctx.semantic.tokenSlice(name_token))) continue;

        const init = var_decl.ast.init_node.unwrap() orelse continue;
        if (std.mem.eql(u8, expected, ast.getNodeSource(init))) return true;
    }
    return false;
}

fn hasMemAlias(ctx: *LinterContext) bool {
    return hasTopLevelAlias(ctx, "mem", "std.mem");
}

fn hasAllocatorAlias(ctx: *LinterContext) bool {
    return hasTopLevelAlias(ctx, "Allocator", "mem.Allocator") or
        hasTopLevelAlias(ctx, "Allocator", "std.mem.Allocator");
}

/// Does the chain's left-most identifier resolve to `std.mem`?
fn resolvesToStdMem(ctx: *LinterContext, chain: Chain) bool {
    const init = ast_utils.resolveConstAlias(ctx, chain.leftmost) orelse return false;
    return std.mem.eql(u8, "std.mem", ctx.ast().getNodeSource(init));
}

fn chainSpan(ctx: *LinterContext, chain: Chain) zlint.span.Span {
    const first = ctx.semantic.tokenSpan(chain.tokens[0]);
    const last = ctx.semantic.tokenSpan(chain.tokens[chain.len - 1]);
    return .new(first.start, last.end);
}

fn memDiagnostic(ctx: *LinterContext, chain: Chain) Error {
    return ctx.diagnosticf(
        "Use the `mem` alias instead of `std.mem.{s}`. Declare `const mem = std.mem;`.",
        .{chain.segments[2]},
        .{zlint.span.LabeledSpan.unlabeled(chainSpan(ctx, chain))},
    );
}

fn memNamespaceDiagnostic(ctx: *LinterContext, chain: Chain) Error {
    return ctx.diagnostic(
        "Use the `mem` alias instead of `std.mem`. Declare `const mem = std.mem;`.",
        .{zlint.span.LabeledSpan.unlabeled(chainSpan(ctx, chain))},
    );
}

fn allocatorDiagnostic(ctx: *LinterContext, chain: Chain) Error {
    return ctx.diagnosticf(
        "Use the `Allocator` alias instead of `{s}`. Declare `const Allocator = mem.Allocator;`.",
        .{ctx.ast().getNodeSource(chain.node)},
        .{zlint.span.LabeledSpan.unlabeled(chainSpan(ctx, chain))},
    );
}

pub fn runOnNode(_: *const StdAliases, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.idx;
    if (ctx.ast().nodeTag(node) != .field_access) return;
    // Only inspect the outermost field access in a chain.
    if (ctx.links().getParent(node)) |parent| {
        if (ctx.ast().nodeTag(parent) == .field_access and
            ctx.ast().nodeData(parent).node_and_token[0] == node)
        {
            return;
        }
    }

    const chain = getChain(ctx, node) orelse return;

    // `std.mem` used as a value, outside of `const mem = std.mem;`.
    if (chain.startsWith("std") and chain.len == 2 and
        std.mem.eql(u8, chain.segments[1], "mem") and
        !isDeclInit(ctx, node, "mem"))
    {
        ctx.report(memNamespaceDiagnostic(ctx, chain));
        return;
    }

    // `std.mem.<member>`
    if (chain.startsWith("std") and chain.len >= 3 and std.mem.eql(u8, chain.segments[1], "mem")) {
        if (chain.len == 3 and std.mem.eql(u8, chain.segments[2], "Allocator")) {
            ctx.report(allocatorDiagnostic(ctx, chain));
            return;
        }

        if (chain.len == 3) {
            ctx.report(memDiagnostic(ctx, chain));
        }
        return;
    }

    // `mem.Allocator`, but only when `mem` resolves to `std.mem`.
    if (chain.len == 2 and chain.startsWith("mem") and
        std.mem.eql(u8, chain.segments[1], "Allocator") and
        !isDeclInit(ctx, node, "Allocator") and
        resolvesToStdMem(ctx, chain))
    {
        ctx.report(allocatorDiagnostic(ctx, chain));
    }
}

pub fn rule(self: *StdAliases) Rule {
    return Rule.init(self);
}

const support = @import("tests/std_aliases_support.zig");
test StdAliases {
    const t = std.testing;
    var rule_impl = StdAliases{};
    const rule_value = rule_impl.rule();

    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\const mem = std.mem;
        \\const Allocator = mem.Allocator;
        \\fn eql(a: []const u8, b: []const u8) bool {
        \\    return mem.eql(u8, a, b);
        \\}
        \\fn allocatorCopy(allocator: Allocator) ![]u8 {
        \\    return allocator.dupe(u8, "x");
        \\}
        \\
        ,
        \\const std = @import("std");
        \\fn foo() void {
        \\    _ = std.testing;
        \\}
        \\
        ,
        \\const mem = struct {
        \\    const Allocator = u32;
        \\};
        \\fn foo(allocator: mem.Allocator) void { _ = allocator; }
        \\
        ,
        \\fn foo(mem: struct { const Allocator = u32; }, allocator: mem.Allocator) void {
        \\    _ = allocator;
        \\}
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
            .source =
            \\const std = @import("std");
            \\fn eql(a: []const u8, b: []const u8) bool {
            \\    return std.mem.eql(u8, a, b);
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\fn foo(allocator: std.mem.Allocator) void { _ = allocator; }
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const Allocator = std.mem.Allocator;
            \\fn foo(allocator: Allocator) void { _ = allocator; }
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const mem = std.mem;
            \\const Allocator = mem.Allocator;
            \\fn foo(allocator: mem.Allocator) void { _ = allocator; }
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const mem = std.mem;
            \\fn eql(a: []const u8, b: []const u8) bool {
            \\    return std.mem.eql(u8, a, b);
            \\}
            \\
            ,
            .count = 1,
        },
        .{
            .source =
            \\const std = @import("std");
            \\const memory = std.mem;
            \\
            ,
            .count = 1,
        },
    };

    for (fail) |case| {
        try support.expectFailCount(t.allocator, rule_value, case.source, case.count);
    }
}
