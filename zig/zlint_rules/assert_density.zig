//! ## What This Rule Does
//!
//! Implements the assertion-density rule from `docs/code-style-guide.md` §11:
//!
//! > Every non-trivial function should average at least two assertions, and a
//! > non-trivial function with none is under-specified.
//!
//! A function is non-trivial when it is longer than `min_lines` or has at least
//! `min_complexity` cyclomatic complexity. Assertions are `std.debug.assert`
//! calls in the function body.
//!
//! The rule reports two things:
//!
//! - a non-trivial function with zero assertions (the hard finding);
//! - a file whose assertion density is below `min_density` (advisory).
//!
//! ## Baseline
//!
//! `baseline` grandfathers existing zero-assert functions:
//!
//! ```json
//! "assert-density": ["error", {
//!   "baseline": [
//!     { "file": "src/foo.zig", "function": "parse", "hash": "0x1a2b3c4d5e6f7890" }
//!   ]
//! }]
//! ```
//!
//! A baselined function is reported as a warning instead of the configured
//! severity. The hash covers the function's token stream, so editing the
//! function invalidates the entry and the finding becomes an error again. The
//! diagnostic message carries the fingerprint for the baseline generator.
//!
//! This rule is off by default and enabled by the project's `zlint.json`.

const std = @import("std");
const mem = std.mem;
const zlint = @import("zlint");

const Ast = zlint.Semantic.Ast;
const Rule = zlint.linter.rule.Rule;
const LinterContext = zlint.linter.lint_context;
const Severity = zlint.linter.Error.Severity;
const ast_utils = zlint.linter.ast_utils;

const AssertDensity = @This();

/// Total assertions must be at least `min_density * non-trivial functions`.
min_density: u32 = 2,
/// Functions at or below this line count are trivial unless they are complex.
min_lines: u32 = 5,
/// Functions at or above this complexity are non-trivial even when short.
min_complexity: u32 = 3,
allow_tests: bool = true,
/// Grandfathered zero-assert functions. See the module docs.
baseline: []const BaselineEntry = &.{},

pub const BaselineEntry = struct {
    file: []const u8,
    function: []const u8,
    hash: []const u8,
};

pub const meta: Rule.Meta = .{
    .name = "assert-density",
    .category = .style,
    .default = .off,
};

pub fn runOnce(self: *const AssertDensity, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const nodes = ctx.semantic.nodes();
    const path = ctx.source.pathname orelse "";

    var non_trivial: u32 = 0;
    var total_asserts: u32 = 0;
    var first_function: ?Ast.Node.Index = null;

    for (0..nodes.len) |i| {
        const idx: Ast.Node.Index = @fromBackingInt(@intCast(i));
        const node = nodes.get(i);
        if (node.tag != .fn_decl) continue;
        if (self.allow_tests and ast_utils.isInTest(ctx, idx)) continue;

        var proto_buf: [1]Ast.Node.Index = undefined;
        const proto = ast.fullFnProto(&proto_buf, idx) orelse continue;
        const name_token = proto.name_token orelse continue;

        const first = ast.firstToken(idx);
        const last = ast.lastToken(idx);
        const assert_count = countAsserts(ast, first, last);
        const complexity = complexityOf(ast, first, last);
        const lines = linesOf(ctx, first, last);

        if (lines <= self.min_lines and complexity < self.min_complexity) continue;

        non_trivial += 1;
        total_asserts += assert_count;
        if (first_function == null) first_function = idx;
        if (assert_count != 0) continue;

        const name = ast.tokenSlice(name_token);
        const fingerprint = fingerprintOf(ast, first, last);
        var fingerprint_buf: [18]u8 = undefined;
        const fingerprint_text = std.fmt.bufPrint(&fingerprint_buf, "0x{x}", .{fingerprint}) catch unreachable;
        const diag = ctx.diagnosticf(
            "function `{s}` has no assertions ({d} lines, complexity {d}, fingerprint {s})",
            .{ name, lines, complexity, fingerprint_text },
            .{ctx.spanN(idx)},
        );

        if (isBaselined(self.baseline, path, name, fingerprint_text)) {
            reportAt(ctx, diag, .warning);
        } else {
            ctx.report(diag);
        }
    }

    if (non_trivial == 0) return;
    if (total_asserts >= self.min_density * non_trivial) return;

    const diag = ctx.diagnosticf(
        "assertion density is below the minimum ({d} assertions across {d} non-trivial functions, minimum {d} per function)",
        .{ total_asserts, non_trivial, self.min_density },
        .{ctx.spanN(first_function.?)},
    );
    // Density is a ratchet, not the hard gate; the zero-assert floor above is.
    reportAt(ctx, diag, .warning);
}

fn isBaselined(
    entries: []const BaselineEntry,
    path: []const u8,
    function: []const u8,
    hash: []const u8,
) bool {
    for (entries) |entry| {
        if (!mem.eql(u8, entry.hash, hash)) continue;
        if (!mem.eql(u8, entry.file, path)) continue;
        if (!mem.eql(u8, entry.function, function)) continue;
        return true;
    }
    return false;
}

fn countAsserts(ast: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) u32 {
    var count: u32 = 0;
    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (isStdDebugAssert(ast, tok, last)) count += 1;
    }
    return count;
}

fn isStdDebugAssert(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 4 > last) return false;
    if (ast.tokenTag(tok) != .identifier) return false;
    if (!mem.eql(u8, ast.tokenSlice(tok), "std")) return false;
    if (ast.tokenTag(tok + 1) != .period) return false;
    if (ast.tokenTag(tok + 2) != .identifier) return false;
    if (!mem.eql(u8, ast.tokenSlice(tok + 2), "debug")) return false;
    if (ast.tokenTag(tok + 3) != .period) return false;
    if (ast.tokenTag(tok + 4) != .identifier) return false;
    return mem.eql(u8, ast.tokenSlice(tok + 4), "assert");
}

fn complexityOf(ast: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) u32 {
    var complexity: u32 = 1;
    var tok = first;
    while (tok <= last) : (tok += 1) {
        switch (ast.tokenTag(tok)) {
            .keyword_if,
            .keyword_while,
            .keyword_for,
            .keyword_switch,
            .keyword_catch,
            .keyword_orelse,
            .keyword_and,
            .keyword_or,
            => complexity += 1,
            else => {},
        }
    }
    return complexity;
}

fn linesOf(ctx: *const LinterContext, first: Ast.TokenIndex, last: Ast.TokenIndex) u32 {
    const ast = ctx.ast();
    const start = ast.tokenToSpan(first).start;
    const end = ast.tokenToSpan(last).end;
    const text = ctx.source.text()[start..end];

    var lines: u32 = 1;
    for (text) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

/// Stable across formatting and comments; changes when the token stream changes.
pub fn fingerprintOf(ast: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var tok = first;
    while (tok <= last) : (tok += 1) {
        hasher.update(ast.tokenSlice(tok));
        hasher.update(&[_]u8{0});
    }
    return hasher.final();
}

/// `zlint` applies the rule's configured severity in `_report`. Override the
/// diagnostic that was just appended so baselined findings stay visible as
/// warnings without changing the rule's severity for new findings.
fn reportAt(ctx: *LinterContext, diag: zlint.linter.Error, severity: Severity) void {
    const before = ctx.diagnostics.items.len;
    ctx.report(diag);
    if (ctx.diagnostics.items.len > before) {
        ctx.diagnostics.items[before].err.severity = severity;
    }
}

pub fn rule(self: *AssertDensity) Rule {
    return Rule.init(self);
}

const support = @import("tests/assert_density_support.zig");

test AssertDensity {
    const t = std.testing;

    const pass = &[_][:0]const u8{
        // Trivial accessor: short and straight-line.
        \\fn get(value: u32) u32 {
        \\    return value;
        \\}
        \\
        ,
        // Non-trivial, two assertions, density met.
        \\fn parse(a: u32, b: u32) u32 {
        \\    std.debug.assert(a > 0);
        \\    std.debug.assert(b > 0);
        \\    if (a > b) return a;
        \\    return b;
        \\}
        \\
        ,
        // Short but complex enough to be non-trivial, with two assertions.
        \\fn pick(a: u32, b: u32) u32 {
        \\    std.debug.assert(a > 0);
        \\    std.debug.assert(b > 0);
        \\    if (a == b) return a;
        \\    if (a > b) return a;
        \\    return b;
        \\}
        \\
        ,
        // Test-local functions are skipped.
        \\test "pick" {
        \\    const S = struct {
        \\        fn pick(a: u32) u32 {
        \\            if (a > 0) return a;
        \\            return 0;
        \\        }
        \\    };
        \\    _ = S;
        \\}
        \\
        ,
    };

    for (pass) |source| {
        var rule_impl = AssertDensity{};
        const rule_value = rule_impl.rule();
        try support.expectPass(t.allocator, rule_value, source);
    }

    // Non-trivial (six lines), no assertions: zero floor plus density warning.
    const failing =
        \\fn parse(value: u32) u32 {
        \\    if (value > 0) {
        \\        return value;
        \\    } else {
        \\        return 0;
        \\    }
        \\}
        \\
    ;

    var fail_impl = AssertDensity{};
    try support.expectFailCount(t.allocator, fail_impl.rule(), failing, 2);

    // Grandfather the function: the zero-assert finding becomes a warning.
    const diagnostics = (try support.run(t.allocator, fail_impl.rule(), failing)).?;
    defer support.deinit(t.allocator, diagnostics);

    const hash = fingerprintFromDiagnostics(diagnostics);
    const entries = [_]AssertDensity.BaselineEntry{
        .{ .file = "test.zig", .function = "parse", .hash = hash },
    };

    var baselined_impl = AssertDensity{ .baseline = &entries };
    const baselined_rule = baselined_impl.rule();
    const baselined = try support.run(t.allocator, baselined_rule, failing);
    defer if (baselined) |list| support.deinit(t.allocator, list);

    try t.expect(baselined != null);
    try t.expectEqual(@as(usize, 2), baselined.?.items.len);
    for (baselined.?.items) |diagnostic| {
        try t.expectEqual(Severity.warning, diagnostic.err.severity);
    }

    // Editing the function invalidates the baseline: the finding is an error.
    const edited =
        \\fn parse(value: u32) u32 {
        \\    if (value > 0) {
        \\        return value;
        \\    } else {
        \\        return 1;
        \\    }
        \\    // Edited.
        \\}
        \\
    ;

    const edited_diagnostics = (try support.run(t.allocator, baselined_rule, edited)).?;
    defer support.deinit(t.allocator, edited_diagnostics);

    var errors: usize = 0;
    for (edited_diagnostics.items) |diagnostic| {
        if (diagnostic.err.severity == .err) errors += 1;
    }
    try t.expect(errors >= 1);
}

fn fingerprintFromDiagnostics(diagnostics: zlint.linter.lint_context.Diagnostic.List) []const u8 {
    for (diagnostics.items) |diagnostic| {
        const message = diagnostic.err.message.borrow();
        const marker = "fingerprint ";
        const start = mem.indexOf(u8, message, marker) orelse continue;
        const rest = message[start + marker.len ..];
        const end = mem.indexOfAny(u8, rest, " ,)") orelse rest.len;
        return rest[0..end];
    }
    @panic("assert-density diagnostic did not include a fingerprint");
}
