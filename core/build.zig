pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zfm", .{
        .root_source_file = b.path("src/zfm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const step_test = b.step("test", "Run tests");

    const mod_test = b.addTest(.{
        .root_module = mod,
    });
    const mod_test_run = b.addRunArtifact(mod_test);
    step_test.dependOn(&mod_test_run.step);
}

const std = @import("std");
