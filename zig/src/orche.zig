//! Linux-only task runner for OrchEngine projects.
//!
//! The command surface stays stable; the bash task bodies are temporary and
//! tracked by the multiplatform follow-up ticket.

const std = @import("std");
const Io = std.Io;

const usage =
    \\orche — OrchEngine tooling runner
    \\
    \\usage: orche <command> [target] [options]
    \\
    \\commands:
    \\  lint              build/select zlint and run it on target
    \\  verify            lint, gen-proto, build, test, TSan, generation, e2e
    \\  e2e               run the workflow end-to-end check
    \\  generation-check  check generated files are current
    \\  coverage          build test binaries and run kcov
    \\  coverage-view     print or open the coverage report
    \\  test-audit        run coverage and print the test count
    \\  ui-proof          build the UI and run the Playwright proof suite
    \\  ui-proof-view     open the UI proof gallery
    \\  typecheck-js      type-check the editor JavaScript
    \\  test-js           run the editor JavaScript tests
    \\  build-ui          build the editor UI
    \\  test-ui           run the editor UI tests
    \\  test-ui-update    update the editor UI snapshots
    \\  watch-ui          watch and rebuild the editor UI
    \\
    \\options:
    \\  --release         use the pinned prebuilt zlint (CI)
    \\  --source          build zlint from the tooling checkout (default)
    \\  --tools-dir DIR   orchengine-tools checkout (default: ../orchengine-tools)
    \\  -h, --help        print this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return;
    }

    const command = args[1];
    var target: []const u8 = ".";
    var release = false;
    var tools_arg: ?[]const u8 = null;

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--release")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--source")) {
            release = false;
        } else if (std.mem.eql(u8, arg, "--tools-dir")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("orche: --tools-dir requires a value\n", .{});
                std.process.exit(2);
            }
            tools_arg = args[i];
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("orche: unknown option '{s}'\n", .{arg});
            std.process.exit(2);
        } else {
            target = arg;
        }
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const target_abs = try std.fs.path.resolve(arena, &.{ cwd, target });
    const tools_dir = try resolveToolsDir(arena, cwd, target_abs, tools_arg, init.environ_map);
    const zig_dir = try std.fs.path.join(arena, &.{ tools_dir, "zig" });

    dispatch(io, arena, zig_dir, target_abs, command, release) catch |err| {
        std.debug.print("orche: {s} failed: {s}\n", .{ command, @errorName(err) });
        std.process.exit(1);
    };
}

fn resolveToolsDir(
    arena: std.mem.Allocator,
    cwd: []const u8,
    target: []const u8,
    tools_arg: ?[]const u8,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    if (tools_arg) |t| return std.fs.path.resolve(arena, &.{ cwd, t });
    if (env.get("ORCHENGINE_TOOLS")) |t| return std.fs.path.resolve(arena, &.{ cwd, t });
    return std.fs.path.resolve(arena, &.{ target, "..", "orchengine-tools" });
}

fn dispatch(
    io: Io,
    arena: std.mem.Allocator,
    zig_dir: []const u8,
    target: []const u8,
    command: []const u8,
    release: bool,
) !void {
    if (std.mem.eql(u8, command, "lint")) return cmdLint(io, arena, zig_dir, target, release);
    if (std.mem.eql(u8, command, "verify")) return cmdVerify(io, arena, zig_dir, target, release);
    if (std.mem.eql(u8, command, "e2e")) return cmdE2e(io, arena, zig_dir, target);
    if (std.mem.eql(u8, command, "generation-check")) return cmdGenerationCheck(io, arena, zig_dir, target);
    if (std.mem.eql(u8, command, "coverage")) return cmdCoverage(io, arena, zig_dir, target);
    if (std.mem.eql(u8, command, "coverage-view")) return runTask(io, arena, zig_dir, "coverage-view.sh", target);
    if (std.mem.eql(u8, command, "test-audit")) return cmdTestAudit(io, arena, zig_dir, target);
    if (std.mem.eql(u8, command, "ui-proof")) return cmdUiProof(io, arena, zig_dir, target);
    if (std.mem.eql(u8, command, "ui-proof-view")) return runTask(io, arena, zig_dir, "ui-proof-view.sh", target);
    if (std.mem.eql(u8, command, "typecheck-js")) return runNpm(io, arena, target, &.{ "run", "typecheck:js" });
    if (std.mem.eql(u8, command, "test-js")) return runNpm(io, arena, target, &.{ "run", "test:js" });
    if (std.mem.eql(u8, command, "build-ui")) return runNpm(io, arena, target, &.{ "run", "build:ui" });
    if (std.mem.eql(u8, command, "test-ui")) return cmdTestUi(io, arena, target, false);
    if (std.mem.eql(u8, command, "test-ui-update")) return cmdTestUi(io, arena, target, true);
    if (std.mem.eql(u8, command, "watch-ui")) return runNpm(io, arena, target, &.{ "run", "dev:ui" });

    std.debug.print("orche: unknown command '{s}'\n\n{s}", .{ command, usage });
    std.process.exit(2);
}

fn cmdLint(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8, release: bool) !void {
    var bin: []const u8 = undefined;
    if (release) {
        try runTool(io, arena, zig_dir, "zlint-download");
        bin = try std.fs.path.join(arena, &.{ zig_dir, ".tmp", "zlint", "zlint" });
    } else {
        try runTool(io, arena, zig_dir, "zlint-rules-build");
        bin = try std.fs.path.join(arena, &.{ zig_dir, "bin", "zlint-orche" });
    }
    try run(io, &.{bin}, target);
    try runTask(io, arena, zig_dir, "fmt-check.sh", target);
}

fn cmdVerify(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8, release: bool) !void {
    try cmdLint(io, arena, zig_dir, target, release);
    try run(io, &.{ "zig", "build", "gen-proto" }, target);
    try run(io, &.{ "zig", "build" }, target);
    try run(io, &.{ "zig", "build", "test" }, target);
    try run(io, &.{ "zig", "build", "test", "-Dtsan=true" }, target);
    try runTask(io, arena, zig_dir, "generation-check.sh", target);
    try runTask(io, arena, zig_dir, "workflow-e2e.sh", target);
}

fn cmdE2e(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8) !void {
    try run(io, &.{ "zig", "build" }, target);
    try runTask(io, arena, zig_dir, "workflow-e2e.sh", target);
}

fn cmdGenerationCheck(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8) !void {
    try run(io, &.{ "zig", "build", "gen-proto" }, target);
    try run(io, &.{ "zig", "build" }, target);
    try runTask(io, arena, zig_dir, "generation-check.sh", target);
}

fn cmdCoverage(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8) !void {
    try run(io, &.{ "zig", "build", "test-bin" }, target);
    try runTask(io, arena, zig_dir, "coverage.sh", target);
}

fn cmdTestAudit(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8) !void {
    try cmdCoverage(io, arena, zig_dir, target);
    try runTask(io, arena, zig_dir, "test-audit.sh", target);
}

fn cmdUiProof(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, target: []const u8) !void {
    try run(io, &.{ "zig", "build" }, target);
    try runNpm(io, arena, target, &.{ "run", "build:ui" });
    try runTask(io, arena, zig_dir, "ui-proof.sh", target);
}

fn cmdTestUi(io: Io, arena: std.mem.Allocator, target: []const u8, update: bool) !void {
    try run(io, &.{ "zig", "build" }, target);
    if (update) {
        try runNpm(io, arena, target, &.{ "run", "test:ui:update" });
    } else {
        try runNpm(io, arena, target, &.{ "run", "test:ui" });
    }
}

fn runTool(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, name: []const u8) !void {
    const script = try std.fs.path.join(arena, &.{ zig_dir, name });
    try run(io, &.{ "bash", script }, null);
}

fn runTask(io: Io, arena: std.mem.Allocator, zig_dir: []const u8, name: []const u8, target: []const u8) !void {
    const script = try std.fs.path.join(arena, &.{ zig_dir, "tasks", name });
    try run(io, &.{ "bash", script, target }, null);
}

fn runNpm(io: Io, arena: std.mem.Allocator, target: []const u8, args: []const []const u8) !void {
    const editor = try std.fs.path.join(arena, &.{ target, "internal", "editor" });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "npm");
    try argv.appendSlice(arena, args);
    try run(io, argv.items, editor);
}

fn run(io: Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    std.debug.print("orche:", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
    });
    const term = try child.wait(io);
    if (!term.success()) return error.CommandFailed;
}
