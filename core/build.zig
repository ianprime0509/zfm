pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zfm", .{
        .root_source_file = b.path("src/zfm.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = mod;
}

const std = @import("std");
