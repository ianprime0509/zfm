pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zfm = b.dependency("zfm", .{
        .target = target,
        .optimize = optimize,
    }).module("zfm");

    const translate_c = b.dependency("translate_c", .{});
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const miniaudio = b.dependency("miniaudio", .{});
    t.addIncludePath(miniaudio.path("."));
    t.mod.addCSourceFile(.{ .file = miniaudio.path("miniaudio.c") });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zfm", .module = zfm },
            .{ .name = "c", .module = t.mod },
        },
    });
    const exe = b.addExecutable(.{
        .name = "zfm",
        .root_module = mod,
    });
    if (b.option(bool, "force-llvm", "Force LLVM usage") orelse false) exe.use_llvm = true;
    b.installArtifact(exe);
}

const std = @import("std");
const Translator = @import("translate_c").Translator;
