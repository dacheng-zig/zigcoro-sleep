const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // add zigcoro dependency
    const zigcoro_dep = b.dependency("zigcoro", .{});
    const zigcoro = zigcoro_dep.module("libcoro");
    exe_mod.addImport("zigcoro", zigcoro);

    // add xev dependency
    const xev_dep = b.dependency("libxev", .{});
    const xev = xev_dep.module("xev");
    exe_mod.addImport("xev", xev);

    const exe = b.addExecutable(.{
        .name = "zigcoro_sleep",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
