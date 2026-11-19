const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zigdepends",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    const run_step = b.step("run", "Run zigdepends");
    run_step.dependOn(&run.step);

    const orche_mod = b.createModule(.{
        .root_source_file = b.path("src/orche.zig"),
        .target = target,
        .optimize = optimize,
    });
    const orche = b.addExecutable(.{
        .name = "orche",
        .root_module = orche_mod,
    });
    b.installArtifact(orche);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
