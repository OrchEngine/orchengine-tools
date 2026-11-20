//! Snapshot-free helpers for testing custom lint rules.
//!
//! `zlint.linter.tester.RuleTester` writes snapshots into the zlint checkout,
//! which custom rules must not do. These helpers run a rule directly and
//! assert the diagnostic count.

const std = @import("std");
const zlint = @import("zlint");

const Diagnostic = zlint.linter.lint_context.Diagnostic;

pub fn expectPass(
    allocator: std.mem.Allocator,
    rule: zlint.lint.Rule,
    source_text: [:0]const u8,
) !void {
    const diagnostics = try run(allocator, rule, source_text);
    if (diagnostics) |list| {
        deinit(allocator, list);
        return error.ExpectedPass;
    }
}

pub fn expectFailCount(
    allocator: std.mem.Allocator,
    rule: zlint.lint.Rule,
    source_text: [:0]const u8,
    expected: usize,
) !void {
    const diagnostics = try run(allocator, rule, source_text);
    if (diagnostics == null) return error.ExpectedFailure;
    const list = diagnostics.?;
    defer deinit(allocator, list);

    if (list.items.len != expected) {
        std.debug.print(
            "Expected {d} diagnostics, got {d} for:\n{s}\n",
            .{ expected, list.items.len, source_text },
        );
        return error.UnexpectedDiagnosticCount;
    }
}

fn run(
    allocator: std.mem.Allocator,
    rule: zlint.lint.Rule,
    source_text: [:0]const u8,
) !?Diagnostic.List {
    var source = try zlint.Source.fromString(
        allocator,
        try allocator.dupeSentinel(u8, source_text, 0),
        try allocator.dupe(u8, "test.zig"),
    );
    defer source.deinit();

    var builder = zlint.Semantic.Builder.init(allocator);
    defer builder.deinit();
    builder.withSource(&source);

    var result = try builder.build(source.text());
    defer result.deinit();
    if (result.hasErrors()) return error.AnalysisFailed;

    var linter = zlint.lint.Linter.initEmpty(allocator);
    defer linter.deinit();
    try linter.registerRule(.err, rule);

    var diagnostics: ?Diagnostic.List = null;
    linter.runOnSource(std.testing.io, &result.value, &source, &diagnostics) catch |err| {
        if (err != error.LintingFailed) return err;
    };
    return diagnostics;
}

fn deinit(allocator: std.mem.Allocator, list: Diagnostic.List) void {
    var owned = list;
    for (owned.items) |*diagnostic| diagnostic.deinit(allocator);
    owned.deinit();
}
