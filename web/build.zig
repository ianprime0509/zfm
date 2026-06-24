const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const optimize = b.standardOptimizeOption(.{});

    const zfm = b.dependency("zfm_core", .{
        .target = target,
        .optimize = optimize,
    }).module("zfm");

    const mod_synth = b.createModule(.{
        .root_source_file = b.path("src/synth.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfm", .module = zfm },
        },
    });
    const exe_synth = b.addExecutable(.{
        .name = "audio",
        .root_module = mod_synth,
    });
    exe_synth.rdynamic = true;
    exe_synth.entry = .disabled;
    b.installArtifact(exe_synth);

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
