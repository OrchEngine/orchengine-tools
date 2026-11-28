//! ## What This Rule Does
//!
//! Implements the assertion-density rule from `docs/code-style-guide.md` §11:
//!
//! > Every non-trivial function should average at least two assertions, and a
//! > non-trivial function with none is under-specified.
//!
//! The rule adapts JPL Rule 16: a non-trivial function needs one check. Set
//! `min_density` to 2 to enforce the Power of Ten two-per-function average.
//!
//! A function is non-trivial when it has at least `min_complexity` cyclomatic
//! complexity. Line count does not make a function non-trivial, so a long
//! straight-line function stays trivial.
//!
//! A check is either a `std.debug.assert` call (including the common
//! `const assert = std.debug.assert;` alias) or any explicit error: `error.X`,
//! a named `Error.X` set value, or a propagated error such as `return err` from
//! a `catch |err|` or `else |err|` capture. Every form is a recovery path.
//!
//! Failure channels that are not Zig errors also count: `@compileError` and an
//! explicit failure status assigned to `.status` (`.forbidden`, `.failed`, ...).
//! These are the equivalents of an error return in compile-time and HTTP code.
//!
//! JPL Rule 16 defines an assertion as a checked condition with recovery, so an
//! error return is the recovery half of the same pattern. Assertions document
//! programmer invariants; error returns cover recoverable input.
//!
//! The rule reports:
//!
//! - a non-trivial function with no checks (the hard finding);
//! - a file whose check density is below `min_density` (advisory; only checked
//!   when `min_density` is greater than 1).
//!
//! ## Baseline
//!
//! `baseline` grandfathers existing zero-check functions:
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
//! ## Suppression
//!
//! Use zlint's disable directives for one-off exceptions, with a reason:
//!
//! ```zig
//! // zlint-disable-next-line assert-density -- CLI dispatch, no invariants
//! fn dispatch(...) void { ... }
//! ```
//!
//! `// zlint-disable assert-density -- <reason>` disables the rule for the file.
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

/// Total checks must be at least `min_density * non-trivial functions`.
/// Defaults to 1, JPL Rule 16's per-function floor. Set to 2 for the Power of
/// Ten average. Values at or below 1 disable the advisory warning.
min_density: u32 = 1,
/// Functions at or above this complexity are non-trivial.
min_complexity: u32 = 5,
allow_tests: bool = true,
/// Grandfathered zero-check functions. See the module docs.
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
    var total_checks: u32 = 0;
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
        const check_count = countChecks(ast, first, last);
        const complexity = complexityOf(ast, first, last);
        const lines = linesOf(ctx, first, last);

        if (complexity < self.min_complexity) continue;

        non_trivial += 1;
        total_checks += check_count;
        if (first_function == null) first_function = idx;
        if (check_count != 0) continue;

        const name = ast.tokenSlice(name_token);
        const fingerprint = fingerprintOf(ast, first, last);
        var fingerprint_buf: [18]u8 = undefined;
        const fingerprint_text = mem.print(&fingerprint_buf, "0x{x}", .{fingerprint}) catch unreachable;
        const diag = ctx.diagnosticf(
            "function `{s}` has no assertions or error returns ({d} lines, complexity {d}, fingerprint {s})",
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
    if (self.min_density <= 1) return;
    if (total_checks >= self.min_density * non_trivial) return;

    const diag = ctx.diagnosticf(
        "assertion density is below the minimum ({d} checks across {d} non-trivial functions, minimum {d} per function)",
        .{ total_checks, non_trivial, self.min_density },
        .{ctx.spanN(first_function.?)},
    );
    // Density is a ratchet, not the hard gate; the zero-check floor above is.
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

const capture_max = 16;

fn countChecks(ast: *const Ast, first: Ast.TokenIndex, last: Ast.TokenIndex) u32 {
    var captures: [capture_max][]const u8 = undefined;
    var capture_count: usize = 0;
    var tok = first;
    while (tok <= last) : (tok += 1) {
        if (!isErrorCaptureDecl(ast, tok, last) or capture_count == capture_max) continue;
        captures[capture_count] = ast.tokenSlice(tok + 2);
        capture_count += 1;
    }

    var count: u32 = 0;
    tok = first;
    while (tok <= last) : (tok += 1) {
        if (isAssertCall(ast, tok, last) or
            isErrorValue(ast, tok, last) or
            isErrorSetValue(ast, tok, last) or
            isPropagatedError(ast, tok, last, captures[0..capture_count]) or
            isCompileError(ast, tok, last) or
            isFailureStatus(ast, tok, last))
        {
            count += 1;
        }
    }
    return count;
}

/// `catch |err|` and `else |err|`: a binding for an error payload.
fn isErrorCaptureDecl(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 3 > last) return false;
    const tag = ast.tokenTag(tok);
    if (tag != .keyword_catch and tag != .keyword_else) return false;
    if (ast.tokenTag(tok + 1) != .pipe) return false;
    if (ast.tokenTag(tok + 2) != .identifier) return false;
    return ast.tokenTag(tok + 3) == .pipe;
}

/// A named error-set value, the project's `Error.X` convention, as in
/// `return self.fail(Error.InvalidWorkflow, ...)`.
fn isErrorSetValue(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 2 > last) return false;
    if (ast.tokenTag(tok) != .identifier) return false;
    if (!mem.eql(u8, ast.tokenSlice(tok), "Error")) return false;
    if (ast.tokenTag(tok + 1) != .period) return false;
    return ast.tokenTag(tok + 2) == .identifier;
}

/// `return err` where `err` is a captured error, or the conventional `err`
/// binding, so a propagated error counts as the recovery.
fn isPropagatedError(
    ast: *const Ast,
    tok: Ast.TokenIndex,
    last: Ast.TokenIndex,
    captures: []const []const u8,
) bool {
    if (tok + 1 > last) return false;
    if (ast.tokenTag(tok) != .keyword_return) return false;
    if (ast.tokenTag(tok + 1) != .identifier) return false;
    const name = ast.tokenSlice(tok + 1);
    if (mem.eql(u8, name, "err")) return true;
    for (captures) |capture| {
        if (mem.eql(u8, capture, name)) return true;
    }
    return false;
}

/// Counts any error value, `error.X`, wherever it appears: `return error.X`,
/// `orelse error.X`, `else error.X`, or a comparison. This is the recovery half
/// of JPL Rule 16's `if (!c_assert(condition)) return ERROR;` pattern. Error
/// set declarations (`error{...}`) have no period and do not match.
fn isErrorValue(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 2 > last) return false;
    if (ast.tokenTag(tok) != .keyword_error) return false;
    if (ast.tokenTag(tok + 1) != .period) return false;
    return ast.tokenTag(tok + 2) == .identifier;
}

/// Counts `std.debug.assert(...)` and the common `assert(...)` alias, which is
/// how most codebases import it.
fn isAssertCall(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 1 > last) return false;
    if (ast.tokenTag(tok) != .identifier) return false;
    if (!mem.eql(u8, ast.tokenSlice(tok), "assert")) return false;
    return ast.tokenTag(tok + 1) == .l_paren;
}

/// A compile-time assertion: failing the build is the strongest recovery.
fn isCompileError(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    _ = last;
    if (ast.tokenTag(tok) != .builtin) return false;
    return mem.eql(u8, ast.tokenSlice(tok), "@compileError");
}

/// Unambiguous failure statuses assigned to a response or result status field.
/// Success states (`ok`, `created`, `found`, ...) are deliberately excluded.
const failure_statuses = [_][]const u8{
    "bad_request",
    "forbidden",
    "unauthorized",
    "not_found",
    "conflict",
    "unsupported_media_type",
    "unprocessable_entity",
    "too_many_requests",
    "internal_server_error",
    "service_unavailable",
    "failed",
};

/// `.status = .forbidden` and friends: an HTTP or result failure response.
fn isFailureStatus(ast: *const Ast, tok: Ast.TokenIndex, last: Ast.TokenIndex) bool {
    if (tok + 3 > last) return false;
    if (ast.tokenTag(tok) != .identifier) return false;
    if (!mem.eql(u8, ast.tokenSlice(tok), "status")) return false;
    if (ast.tokenTag(tok + 1) != .equal) return false;
    if (ast.tokenTag(tok + 2) != .period) return false;
    if (ast.tokenTag(tok + 3) != .identifier) return false;
    const value = ast.tokenSlice(tok + 3);
    for (failure_statuses) |name| {
        if (mem.eql(u8, value, name)) return true;
    }
    return false;
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
        // Non-trivial (complexity five), two assertions, density met.
        \\fn parse(a: u32, b: u32) u32 {
        \\    std.debug.assert(a > 0);
        \\    std.debug.assert(b > 0);
        \\    if (a == 1) return 1;
        \\    if (a == 2) return 2;
        \\    if (a == 3) return 3;
        \\    if (a == 4) return 4;
        \\    return b;
        \\}
        \\
        ,
        // The common `const assert = std.debug.assert;` alias counts.
        \\const assert = std.debug.assert;
        \\fn aliased(a: u32, b: u32) u32 {
        \\    assert(a > 0);
        \\    assert(b > 0);
        \\    if (a == 1) return 1;
        \\    if (a == 2) return 2;
        \\    if (a == 3) return 3;
        \\    if (a == 4) return 4;
        \\    return b;
        \\}
        \\
        ,
        // One assertion is enough at the default density.
        \\fn one(a: u32) u32 {
        \\    std.debug.assert(a > 0);
        \\    if (a == 1) return 1;
        \\    if (a == 2) return 2;
        \\    if (a == 3) return 3;
        \\    if (a == 4) return 4;
        \\    return 0;
        \\}
        \\
        ,
        // An explicit error return is a check too (JPL Rule 16 recovery).
        \\fn fallible(a: u32) !u32 {
        \\    if (a == 1) return 1;
        \\    if (a == 2) return 2;
        \\    if (a == 3) return 3;
        \\    if (a == 4) return 4;
        \\    return error.Invalid;
        \\}
        \\
        ,
        // An error value in a switch `else` is a check even without `return`.
        \\fn lookup(value: u32) !u32 {
        \\    return switch (value) {
        \\        1 => 1,
        \\        2 => 2,
        \\        3 => 3,
        \\        4 => 4,
        \\        else => error.Missing,
        \\    };
        \\}
        \\
        ,
        // A named error-set value is a check: `return Error.X` in a helper style.
        \\fn named(value: u32) !u32 {
        \\    if (value == 1) return 1;
        \\    if (value == 2) return 2;
        \\    if (value == 3) return 3;
        \\    if (value == 4) return 4;
        \\    return Error.Invalid;
        \\}
        \\
        ,
        // A propagated captured error is a check: `catch |err| return err`.
        \\fn propagate(value: u32) !u32 {
        \\    if (value == 1) return 1;
        \\    if (value == 2) return 2;
        \\    if (value == 3) return 3;
        \\    const parsed = step(value) catch |problem| return problem;
        \\    return parsed;
        \\}
        \\
        ,
        // `@compileError` is a compile-time assertion.
        \\fn validated(comptime T: type) void {
        \\    if (@typeInfo(T) != .@"struct") @compileError("not a struct");
        \\    if (!@hasDecl(T, "Input")) @compileError("no Input");
        \\    if (!@hasDecl(T, "Output")) @compileError("no Output");
        \\    if (!@hasDecl(T, "run")) @compileError("no run");
        \\}
        \\
        ,
        // An explicit failure status is a check.
        \\fn guard(value: u32, res: *Response) !void {
        \\    if (value == 1) { res.status = .bad_request; return; }
        \\    if (value == 2) { res.status = .forbidden; return; }
        \\    if (value == 3) { res.status = .not_found; return; }
        \\    if (value == 4) { res.status = .conflict; return; }
        \\    return;
        \\}
        \\
        ,
        // Trivial (complexity two) even with two assertions; the rule stays quiet.
        \\fn pick(a: u32, b: u32) u32 {
        \\    std.debug.assert(a > 0);
        \\    std.debug.assert(b > 0);
        \\    if (a > b) return a;
        \\    return b;
        \\}
        \\
        ,
        // The inline directive suppresses both findings for the next function.
        \\// zlint-disable-next-line assert-density -- intentional dispatch
        \\fn dispatch(value: u32) u32 {
        \\    if (value == 1) return 1;
        \\    if (value == 2) return 2;
        \\    if (value == 3) return 3;
        \\    if (value == 4) return 4;
        \\    return 0;
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

    // Non-trivial (complexity five), no checks: the hard finding.
    const failing =
        \\fn parse(value: u32) u32 {
        \\    if (value == 1) return 1;
        \\    if (value == 2) return 2;
        \\    if (value == 3) return 3;
        \\    if (value == 4) return 4;
        \\    return 0;
        \\}
        \\
    ;

    var fail_impl = AssertDensity{};
    try support.expectFailCount(t.allocator, fail_impl.rule(), failing, 1);

    // The two-per-function average is opt-in.
    var density_impl = AssertDensity{ .min_density = 2 };
    try support.expectFailCount(t.allocator, density_impl.rule(), failing, 2);

    // Grandfather the function: the zero-check finding becomes a warning.
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
    try t.expectEqual(@as(usize, 1), baselined.?.items.len);
    for (baselined.?.items) |diagnostic| {
        try t.expectEqual(Severity.warning, diagnostic.err.severity);
    }

    // Editing the function invalidates the baseline: the finding is an error.
    const edited =
        \\fn parse(value: u32) u32 {
        \\    if (value == 1) return 1;
        \\    if (value == 2) return 2;
        \\    if (value == 3) return 3;
        \\    if (value == 4) return 4;
        \\    return 1;
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
        const start = mem.find(u8, message, marker) orelse continue;
        const rest = message[start + marker.len ..];
        const end = mem.findAny(u8, rest, " ,)") orelse rest.len;
        return rest[0..end];
    }
    @panic("assert-density diagnostic did not include a fingerprint");
}
