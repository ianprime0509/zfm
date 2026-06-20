const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{});

    const zfm = b.dependency("zfm", .{
        .target = target,
        .optimize = optimize,
    }).module("zfm");

    const mod_audio = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfm", .module = zfm },
        },
    });
    const exe_audio = b.addExecutable(.{
        .name = "audio",
        .root_module = mod_audio,
    });
    exe_audio.rdynamic = true;
    exe_audio.entry = .disabled;
    b.installArtifact(exe_audio);

    const mod_compiler = b.createModule(.{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfm", .module = zfm },
        },
    });
    const exe_compiler = b.addExecutable(.{
        .name = "compiler",
        .root_module = mod_compiler,
    });
    exe_compiler.rdynamic = true;
    exe_compiler.entry = .disabled;
    b.installArtifact(exe_compiler);
}
