const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const model = @import("model.zig");
const config = @import("config.zig");
const extract = @import("extract.zig");
const analyze = @import("analyze.zig");
const report = @import("report.zig");
const zlint = @import("zlint.zig");
const check = @import("check.zig");

const Model = model.Model;

const usage =
    \\zigdepends — static dependency, call graph, and technical-debt report for Zig.
    \\
    \\usage: zigdepends [options] [path]
    \\
    \\  path                  directory or .zig file to analyze (default: .)
    \\  -o, --out <dir>       output directory (default: <tools>/zig/out/<project>)
    \\      --title <text>    report title (default: project name)
    \\      --min-debt <n>    hide functions below n debt minutes (default: 0)
    \\      --max-call-nodes <n>  maximum call-graph nodes (default: 80)
    \\      --no-graph        skip Graphviz rendering (HTML still generated)
    \\      --no-open         do not open the report in a browser
    \\      --config <file>   read zigdepends.json (default: <path>/zigdepends.json)
    \\      --exclude <glob>  exclude files or directories (repeatable)
    \\      --include-generated  analyze generated files instead of metrics-boundary mode
    \\      --list-files      print source/generated/excluded file classification
    \\      --no-capabilities skip allocator/Io capability analysis
    \\      --no-fields       skip field read/write and ownership analysis
    \\      --debug-io        count std.debug.print/std.log as Io requirements
    \\      --check           print findings; exit nonzero on errors
    \\      --format <fmt>    check output: text or json (default: text)
    \\      --zlint-report <file>  read zlint JSONL findings
    \\  -h, --help            print this help
    \\
    \\Output: report.html, imports.dot/svg, calls.dot/svg, fields.dot/svg.
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var root_arg: []const u8 = ".";
    var out_arg: ?[]const u8 = null;
    var title_arg: ?[]const u8 = null;
    var min_debt: u32 = 0;
    var max_call_nodes: usize = 80;
    var with_graphs = true;
    var open_report = true;
    var config_arg: ?[]const u8 = null;
    var include_generated = false;
    var list_files = false;
    var track_capabilities = true;
    var track_fields = true;
    var debug_io = false;
    var check_mode = false;
    var check_format: check.Format = .text;
    var zlint_report: ?[]const u8 = null;
    var exclude_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: {s} requires a value\n\n{s}", .{ arg, usage });
                std.process.exit(2);
            }
            out_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--title")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --title requires a value\n", .{});
                std.process.exit(2);
            }
            title_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--min-debt")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --min-debt requires a value\n", .{});
                std.process.exit(2);
            }
            min_debt = std.fmt.parseUnsigned(u32, args[i], 10) catch {
                std.debug.print("zigdepends: invalid --min-debt value '{s}'\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--max-call-nodes")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --max-call-nodes requires a value\n", .{});
                std.process.exit(2);
            }
            max_call_nodes = std.fmt.parseUnsigned(usize, args[i], 10) catch {
                std.debug.print("zigdepends: invalid --max-call-nodes value '{s}'\n", .{args[i]});
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--no-graph")) {
            with_graphs = false;
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            open_report = false;
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --config requires a value\n", .{});
                std.process.exit(2);
            }
            config_arg = args[i];
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --exclude requires a value\n", .{});
                std.process.exit(2);
            }
            try exclude_args.append(arena, args[i]);
        } else if (std.mem.eql(u8, arg, "--include-generated")) {
            include_generated = true;
        } else if (std.mem.eql(u8, arg, "--list-files")) {
            list_files = true;
        } else if (std.mem.eql(u8, arg, "--no-capabilities")) {
            track_capabilities = false;
        } else if (std.mem.eql(u8, arg, "--no-fields")) {
            track_fields = false;
        } else if (std.mem.eql(u8, arg, "--debug-io")) {
            debug_io = true;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --format requires a value\n", .{});
                std.process.exit(2);
            }
            if (std.mem.eql(u8, args[i], "text")) {
                check_format = .text;
            } else if (std.mem.eql(u8, args[i], "json")) {
                check_format = .json;
            } else {
                std.debug.print("zigdepends: invalid --format value '{s}'\n", .{args[i]});
                std.process.exit(2);
            }
        } else if (std.mem.eql(u8, arg, "--zlint-report")) {
            i += 1;
            if (i == args.len) {
                std.debug.print("zigdepends: --zlint-report requires a value\n", .{});
                std.process.exit(2);
            }
            zlint_report = args[i];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("zigdepends: unknown option '{s}'\n\n{s}", .{ arg, usage });
            std.process.exit(2);
        } else {
            root_arg = arg;
        }
    }

    const cwd = try std.process.currentPathAlloc(io, arena);
    const root = if (std.fs.path.isAbsolute(root_arg))
        try std.fs.path.resolve(arena, &.{root_arg})
    else
        try std.fs.path.resolve(arena, &.{ cwd, root_arg });

    var project = std.fs.path.basename(root);
    if (project.len == 0 or std.mem.eql(u8, project, "/") or std.mem.eql(u8, project, ".")) {
        project = "project";
    }

    const title = title_arg orelse project;
    const out_dir = out_arg orelse blk: {
        const home = init.environ_map.get("HOME") orelse ".";
        break :blk try std.fs.path.join(arena, &.{
            home,
            "Projects",
            "orchengine-tools",
            "zig",
            "out",
            project,
        });
    };

    var m = Model{
        .gpa = arena,
        .root = root,
        .title = title,
        .settings = .{
            .min_debt = min_debt,
            .max_call_nodes = max_call_nodes,
        },
        .list_files = list_files,
    };

    if (config_arg) |cfg_arg| {
        const cfg_path = if (std.fs.path.isAbsolute(cfg_arg))
            try std.fs.path.resolve(arena, &.{cfg_arg})
        else
            try std.fs.path.resolve(arena, &.{ cwd, cfg_arg });
        config.load(&m, io, cfg_path) catch |err| {
            std.debug.print("zigdepends: cannot load config {s}: {s}\n", .{ cfg_path, @errorName(err) });
            std.process.exit(2);
        };
    } else {
        const auto_path = try std.fs.path.join(arena, &.{ root, "zigdepends.json" });
        if (Io.Dir.cwd().statFile(io, auto_path, .{})) |stat| {
            if (stat.kind == .file) {
                config.load(&m, io, auto_path) catch |err| {
                    std.debug.print("zigdepends: cannot load config {s}: {s}\n", .{
                        auto_path,
                        @errorName(err),
                    });
                    std.process.exit(2);
                };
            }
        } else |_| {}
    }

    for (exclude_args.items) |pattern| try m.config.exclude.append(arena, pattern);
    if (include_generated) m.config.include_generated_metrics = true;
    if (!track_capabilities) m.config.track_capabilities = false;
    if (!track_fields) m.config.track_fields = false;
    if (debug_io) m.config.debug_io = true;
    m.settings.min_debt = min_debt;
    m.settings.max_call_nodes = max_call_nodes;

    std.debug.print("zigdepends: analyzing {s}\n", .{root});
    try extract.addPath(&m, io, root);

    if (zlint_report) |report_arg| {
        const report_path = if (std.fs.path.isAbsolute(report_arg))
            try std.fs.path.resolve(arena, &.{report_arg})
        else
            try std.fs.path.resolve(arena, &.{ cwd, report_arg });
        zlint.load(&m, io, report_path) catch |err| {
            std.debug.print("zigdepends: cannot read zlint report {s}: {s}\n", .{
                report_path,
                @errorName(err),
            });
            std.process.exit(2);
        };
    }

    try analyze.run(&m);

    if (check_mode) {
        const failed = check.print(&m, io, check_format) catch |err| {
            std.debug.print("zigdepends: cannot write findings: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (failed) std.process.exit(1);
        return;
    }

    const paths = try report.write(&m, io, out_dir, with_graphs);

    var source_files: u32 = 0;
    var generated_files: u32 = 0;
    var direct_caps: u32 = 0;
    var inherited_caps: u32 = 0;
    var pure: u32 = 0;
    var hidden: u32 = 0;
    for (m.files.items) |file| {
        if (file.generated) generated_files += 1 else source_files += 1;
    }
    for (m.fns.items) |f| {
        if (!f.needs_allocator and !f.needs_io) pure += 1;
        if ((f.sig_allocator or f.direct_allocator) or (f.sig_io or f.direct_io)) direct_caps += 1;
        if (f.inherited_allocator or f.inherited_io) inherited_caps += 1;
        if ((f.needs_allocator and f.alloc_source == .inherited) or
            (f.needs_io and f.io_source == .inherited)) hidden += 1;
    }

    std.debug.print(
        "files: {d} source + {d} generated ({d} excluded)  functions: {d}\n" ++
            "calls: {d}  unresolved: {d}\n",
        .{
            source_files,
            generated_files,
            m.excluded_files.items.len,
            m.fns.items.len,
            m.calls.items.len,
            m.unresolved_calls,
        },
    );
    if (m.config.track_capabilities) {
        std.debug.print("capabilities: {d} direct, {d} inherited, {d} pure, {d} unattributed\n", .{
            direct_caps,
            inherited_caps,
            pure,
            hidden,
        });
    }
    if (m.config.track_fields) {
        std.debug.print("fields: {d} types, {d} fields, {d} accesses\n", .{
            m.types.items.len,
            m.fields.items.len,
            m.field_accesses.items.len,
        });
    }
    std.debug.print("findings: {d}  debt: {d} zlint + {d} project minutes\n", .{
        m.findings.items.len,
        m.zlint_debt,
        m.project_debt,
    });
    std.debug.print(
        "import cycles: {d}  recursion: {d}  debt: {d} min (~{d:.1} h)\n" ++
            "report: {s}\n" ++
            "dot:    {s}\n" ++
            "dot:    {s}\n",
        .{
            m.import_cycles.items.len,
            m.call_cycles.items.len,
            m.total_debt,
            @as(f64, @floatFromInt(m.total_debt)) / 60.0,
            paths.html,
            paths.imports_dot,
            paths.calls_dot,
        },
    );
    if (m.config.track_fields) std.debug.print("fields: {s}\n", .{paths.fields_dot});

    if (open_report) openReport(io, arena, cwd, paths.html);
}

fn openReport(io: Io, arena: model.Gpa, cwd: []const u8, html_path: []const u8) void {
    const abs = std.fs.path.resolve(arena, &.{ cwd, html_path }) catch html_path;
    switch (builtin.os.tag) {
        .macos => runOpener(io, &.{ "open", abs }),
        .windows => runOpener(io, &.{ "cmd", "/c", "start", "", abs }),
        else => runOpener(io, &.{ "xdg-open", abs }),
    }
}

fn runOpener(io: Io, argv: []const []const u8) void {
    // Do not wait: xdg-open may hand the process off to a terminal browser or
    // a desktop launcher and keep running until the browser closes.
    _ = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("zigdepends: could not open report: {s}\n", .{@errorName(err)});
    };
}
