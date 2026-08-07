const usage =
    \\Usage: zfm [options...] input
    \\
    \\Compiles and plays or saves ZFM MML files.
    \\
    \\Options:
    \\
    \\  -h, --help              Show this help message
    \\  -F, --no-fade           Do not fade out at the end
    \\  -l, --loops=LOOPS       Number of loops to play
    \\  -o, --output=OUTPUT     Write WAV file to OUTPUT instead of playing
    \\
;

const debug_features = builtin.mode == .debug;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var maybe_input_path: ?[]const u8 = null;
    var maybe_output_path: ?[:0]const u8 = null;
    var options: Player.Options = .{};

    var args: ArgIterator = .init(try init.minimal.args.toSlice(arena));
    _ = args.next();
    while (args.next()) |arg| {
        switch (arg) {
            .option => |option| if (option.is('h', "help")) {
                std.log.info("{s}", .{usage});
                return;
            } else if (option.is('F', "no-fade")) {
                options.fade = false;
            } else if (option.is('l', "loops")) {
                const value = args.optionValue() orelse fatal("missing value for --loops", .{});
                options.loops = std.fmt.parseInt(u8, value, 10) catch fatal("invalid value for --loops: {s}", .{value});
            } else if (option.is('o', "output")) {
                maybe_output_path = args.optionValue() orelse fatal("missing value for --output", .{});
            } else {
                fatal("unrecognized option: {f}", .{option});
            },
            .param => |param| {
                if (maybe_input_path != null) fatal("too many input files", .{});
                maybe_input_path = param;
            },
            .unexpected_value => |unexpected_value| fatal("unexpected value to --{s}: {s}", .{
                unexpected_value.option,
                unexpected_value.value,
            }),
        }
    }

    const input_path = maybe_input_path orelse fatal("missing input file", .{});
    var mod = try readInput(gpa, io, input_path);
    defer mod.deinit(gpa);

    const voices = try gpa.alloc(Synth.Voice, mod.parts.len);
    defer gpa.free(voices);
    const slots = try gpa.alloc(Synth.Slot, mod.parts.len * Synth.Voice.n_slots);
    defer gpa.free(slots);
    var synth: Synth = .init(voices, slots, 0.1);

    const parts = try gpa.alloc(Driver.Part, mod.parts.len);
    defer gpa.free(parts);
    var player: Player = .init(&synth, &mod, parts, options);

    if (maybe_output_path) |output_path| {
        try mainSave(gpa, io, &player, output_path);
    } else {
        try mainPlay(io, &player);
    }
}

fn readInput(gpa: Allocator, io: Io, path: []const u8) !Module {
    if (std.mem.endsWith(u8, path, ".zfm")) {
        return try readInputZfm(gpa, io, path);
    } else if (debug_features and std.mem.endsWith(u8, path, ".mod")) {
        return try readInputMod(gpa, io, path);
    } else {
        fatal("unknown input file type", .{});
    }
}

fn readInputZfm(gpa: Allocator, io: Io, path: []const u8) !Module {
    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .@"1", 0);
    defer gpa.free(source);

    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();
    if (compiler.errors.items.len > 0) {
        for (compiler.errors.items) |err| {
            const loc = compiler.sourceLocation(err.span).start;
            log.err("{}:{}: part {?c}: {f}", .{ loc.line, loc.column, err.part, err });
        }
        return error.CompileError;
    }

    return try compiler.toModule();
}

fn readInputMod(gpa: Allocator, io: Io, path: []const u8) !Module {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try .load(gpa, &reader.interface);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.log.info("{s}", .{usage});
    std.process.exit(1);
}

const Player = struct {
    driver: Driver,
    options: Options,
    volume: f32,

    const Options = struct {
        loops: u8 = 1,
        fade: bool = true,
    };

    const fade_speed = 0.00001;

    fn init(synth: *Synth, mod: *const Module, parts: []Driver.Part, options: Options) Player {
        return .{
            .driver = .init(synth, mod, parts),
            .options = options,
            .volume = 1.0,
        };
    }

    fn ended(player: *const Player) bool {
        return for (player.driver.parts) |part| {
            if (!part.ended and part.cycle < player.options.loops) break false;
        } else true;
    }

    fn render(player: *Player, frames: []Frame) bool {
        for (frames) |*frame| {
            const FrameVec = @Vector(2, f32);
            frame.* = @as(FrameVec, @splat(player.volume)) * @as(FrameVec, player.driver.sample());
            if (player.ended()) {
                player.volume = if (player.options.fade) @max(0.0, player.volume - fade_speed) else 0.0;
            }
        }
        return player.volume > 0.0;
    }
};

fn mainPlay(io: Io, player: *Player) !void {
    var ctx: AudioContext = .init(player, io);

    var audio_config = c.ma_device_config_init(c.ma_device_type_playback);
    audio_config.playback.format = c.ma_format_f32;
    audio_config.playback.channels = 2;
    audio_config.sampleRate = zfm.sample_rate;
    audio_config.dataCallback = audioCallback;
    audio_config.pUserData = &ctx;

    var audio_device: c.ma_device = undefined;
    if (c.ma_device_init(null, &audio_config, &audio_device) != c.MA_SUCCESS) {
        return error.AudioError;
    }
    defer c.ma_device_uninit(&audio_device);
    if (c.ma_device_start(&audio_device) != c.MA_SUCCESS) {
        return error.AudioError;
    }

    const mod = player.driver.mod;
    log.info("Title: {s}", .{mod.strings.string(mod.title)});
    log.info("Composer: {s}", .{mod.strings.string(mod.composer)});
    log.info("Arranger: {s}", .{mod.strings.string(mod.arranger)});

    ctx.done.waitUncancelable(io);
}

fn mainSave(gpa: Allocator, io: Io, player: *Player, path: [:0]const u8) !void {
    if (std.mem.endsWith(u8, path, ".wav")) {
        try saveWav(io, player, path);
    } else if (debug_features and std.mem.endsWith(u8, path, ".mod")) {
        try saveMod(gpa, io, player, path);
    } else if (debug_features and std.mem.endsWith(u8, path, ".json")) {
        try saveJson(io, player, path);
    } else {
        fatal("unknown output file type", .{});
    }
}

fn saveWav(io: Io, player: *Player, path: [:0]const u8) !void {
    const channels: u16 = 2;
    const bits_per_sample: u16 = @bitSizeOf(f32);
    const block_align = channels * @sizeOf(f32);
    const byte_rate = zfm.sample_rate * @as(u32, block_align);

    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);

    var header: [44]u8 = undefined;
    header[0..4].* = "RIFF".*;
    std.mem.writeInt(u32, header[4..8], 0, .little); // chunk size (patched)
    header[8..12].* = "WAVE".*;
    header[12..16].* = "fmt ".*;
    std.mem.writeInt(u32, header[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, header[20..22], 3, .little); // format tag: IEEE float
    std.mem.writeInt(u16, header[22..24], channels, .little);
    std.mem.writeInt(u32, header[24..28], zfm.sample_rate, .little);
    std.mem.writeInt(u32, header[28..32], byte_rate, .little);
    std.mem.writeInt(u16, header[32..34], block_align, .little);
    std.mem.writeInt(u16, header[34..36], bits_per_sample, .little);
    header[36..40].* = "data".*;
    std.mem.writeInt(u32, header[40..44], 0, .little); // data chunk size (patched)
    try writer.interface.writeAll(&header);

    var frames: [256]Frame = undefined;
    var data_bytes: u64 = 0;
    while (true) {
        const done = !player.render(&frames);
        for (frames) |frame| {
            for (frame) |sample| {
                try writer.interface.writeInt(u32, @bitCast(sample), .little);
            }
            data_bytes += @sizeOf(Frame);
        }
        if (done) break;
    }
    try writer.interface.flush();

    var size_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_bytes, @intCast(36 + data_bytes), .little);
    try file.writePositionalAll(io, &size_bytes, 4);
    std.mem.writeInt(u32, &size_bytes, @intCast(data_bytes), .little);
    try file.writePositionalAll(io, &size_bytes, 40);
}

fn saveMod(gpa: Allocator, io: Io, player: *Player, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try player.driver.mod.dump(gpa, &writer.interface);
    try writer.interface.flush();
}

fn saveJson(io: Io, player: *Player, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try player.driver.mod.dumpJson(&writer.interface);
    try writer.interface.flush();
}

const AudioContext = struct {
    player: *Player,
    done: Io.Semaphore,
    io: Io,

    fn init(player: *Player, io: Io) AudioContext {
        return .{
            .player = player,
            .done = .{},
            .io = io,
        };
    }
};

fn audioCallback(
    device: ?*c.ma_device,
    output: ?*anyopaque,
    input: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    _ = input;
    const ctx: *AudioContext = @ptrCast(@alignCast(device.?.pUserData));
    const frames: []Frame = @as([*]Frame, @ptrCast(@alignCast(output.?)))[0..frame_count];
    if (!ctx.player.render(frames)) ctx.done.post(ctx.io);
}

// Inspired by https://github.com/judofyr/parg
const ArgIterator = struct {
    args: []const [:0]const u8,
    index: usize,
    state: union(enum) {
        normal,
        short: [:0]const u8,
        long: struct {
            option: []const u8,
            value: [:0]const u8,
        },
        params_only,
    },

    const Arg = union(enum) {
        option: union(enum) {
            short: u8,
            long: []const u8,

            fn is(option: @This(), short: ?u8, long: ?[]const u8) bool {
                return switch (option) {
                    .short => |b| short == b,
                    .long => |s| std.mem.eql(u8, long orelse return false, s),
                };
            }

            pub fn format(option: @This(), writer: *Writer) Writer.Error!void {
                switch (option) {
                    .short => |b| try writer.print("-{c}", .{b}),
                    .long => |s| try writer.print("--{s}", .{s}),
                }
            }
        },
        param: []const u8,
        unexpected_value: struct {
            option: []const u8,
            value: []const u8,
        },
    };

    fn init(args: []const [:0]const u8) ArgIterator {
        return .{
            .args = args,
            .index = 0,
            .state = .normal,
        };
    }

    fn next(iter: *ArgIterator) ?Arg {
        switch (iter.state) {
            .normal => {
                const arg = iter.nextRaw() orelse return null;
                if (std.mem.eql(u8, arg, "--")) {
                    iter.state = .params_only;
                    return .{ .param = iter.nextRaw() orelse return null };
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    if (std.mem.indexOfScalar(u8, arg, '=')) |equals_index| {
                        const option = arg["--".len..equals_index];
                        iter.state = .{ .long = .{
                            .option = option,
                            .value = arg[equals_index + 1 ..],
                        } };
                        return .{ .option = .{ .long = option } };
                    } else {
                        return .{ .option = .{ .long = arg["--".len..] } };
                    }
                } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
                    if (arg.len > 2) {
                        iter.state = .{ .short = arg["-".len + 1 ..] };
                    }
                    return .{ .option = .{ .short = arg["-".len] } };
                } else {
                    return .{ .param = arg };
                }
            },
            .short => |rest| {
                if (rest.len > 1) {
                    iter.state = .{ .short = rest[1..] };
                }
                return .{ .option = .{ .short = rest[0] } };
            },
            .long => |long| return .{ .unexpected_value = .{
                .option = long.option,
                .value = long.value,
            } },
            .params_only => return .{ .param = iter.nextRaw() orelse return null },
        }
    }

    fn optionValue(iter: *ArgIterator) ?[:0]const u8 {
        switch (iter.state) {
            .normal => return iter.nextRaw(),
            .short => |rest| {
                iter.state = .normal;
                return rest;
            },
            .long => |long| {
                iter.state = .normal;
                return long.value;
            },
            .params_only => unreachable,
        }
    }

    fn nextRaw(iter: *ArgIterator) ?[:0]const u8 {
        if (iter.index == iter.args.len) return null;
        const arg = iter.args[iter.index];
        iter.index += 1;
        return arg;
    }
};

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const log = std.log;
const zfm = @import("zfm");
const Sample = zfm.Sample;
const Frame = zfm.Frame;
const Driver = zfm.Driver;
const Synth = zfm.Synth;
const Module = zfm.Module;
const Compiler = zfm.Compiler;
const c = @import("c");
