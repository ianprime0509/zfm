pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.InvalidArgs;
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, args[1], gpa, .unlimited, .@"1", 0);
    defer gpa.free(source);

    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();
    if (compiler.errors.items.len > 0) {
        for (compiler.errors.items) |e| {
            const loc = compiler.sourceLocation(e.pos);
            log.err("{}:{}: part {?c}: {t}", .{ loc.line, loc.column, e.part, e.tag });
        }
        return error.CompileError;
    }

    var mod = try compiler.toModule();
    defer mod.deinit(gpa);

    const voices = try gpa.alloc(Synth.Voice, mod.parts.len);
    defer gpa.free(voices);
    const slots = try gpa.alloc(Synth.Slot, mod.parts.len * Synth.Voice.n_slots);
    defer gpa.free(slots);
    var synth: Synth = .init(voices, slots, 0.1);

    const parts = try gpa.alloc(Driver.Part, mod.parts.len);
    defer gpa.free(parts);
    var driver: Driver = .init(&synth, &mod, parts);

    var audio_config = c.ma_device_config_init(c.ma_device_type_playback);
    audio_config.playback.format = c.ma_format_f32;
    audio_config.playback.channels = 2;
    audio_config.sampleRate = zfm.sample_rate;
    audio_config.dataCallback = audioCallback;
    audio_config.pUserData = &driver;

    var audio_device: c.ma_device = undefined;
    if (c.ma_device_init(null, &audio_config, &audio_device) != c.MA_SUCCESS) {
        return error.AudioError;
    }
    defer c.ma_device_uninit(&audio_device);
    if (c.ma_device_start(&audio_device) != c.MA_SUCCESS) {
        return error.AudioError;
    }

    log.info("Title: {s}", .{mod.strings.string(mod.title)});
    log.info("Composer: {s}", .{mod.strings.string(mod.composer)});
    log.info("Arranger: {s}", .{mod.strings.string(mod.arranger)});

    while (true) {} // TODO
}

fn audioCallback(
    device: ?*c.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    _ = input;
    const driver: *Driver = @ptrCast(@alignCast(device.?.pUserData));
    const frames: []Frame = @as([*]Frame, @ptrCast(@alignCast(output.?)))[0..frame_count];
    for (frames) |*frame| frame.* = driver.sample();
}

const std = @import("std");
const log = std.log;
const zfm = @import("zfm");
const Frame = zfm.Frame;
const Driver = zfm.Driver;
const Synth = zfm.Synth;
const Compiler = zfm.Compiler;
const c = @import("c");
