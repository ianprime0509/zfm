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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var maybe_input: ?[]const u8 = null;
    var maybe_output: ?[:0]const u8 = null;
    var options: Player.Options = .{};

    var args: ArgIterator = .init(try init.minimal.args.iterateAllocator(arena));
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
                const value = args.optionValue() orelse fatal("missing value for --output", .{});
                maybe_output = try arena.dupeSentinel(u8, value, 0);
            } else {
                fatal("unrecognized option: {f}", .{option});
            },
            .param => |param| {
                if (maybe_input != null) fatal("too many input files", .{});
                maybe_input = try arena.dupe(u8, param);
            },
            .unexpected_value => |unexpected_value| fatal("unexpected value to --{s}: {s}", .{
                unexpected_value.option,
                unexpected_value.value,
            }),
        }
    }

    const input = maybe_input orelse fatal("missing input file", .{});
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, input, gpa, .unlimited, .@"1", 0);
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
    var player: Player = .init(&synth, &mod, parts, options);

    if (maybe_output) |output| {
        try mainSave(io, &player, output);
    } else {
        try mainPlay(io, &player);
    }
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

fn mainSave(io: Io, player: *Player, output: [:0]const u8) !void {
    _ = io; // TODO: use Zig IO rather than miniaudio

    const config = c.ma_encoder_config_init(c.ma_encoding_format_wav, c.ma_format_f32, 2, zfm.sample_rate);
    var encoder: c.ma_encoder = undefined;
    if (c.ma_encoder_init_file(output.ptr, &config, &encoder) != c.MA_SUCCESS) {
        return error.AudioError;
    }
    defer c.ma_encoder_uninit(&encoder);

    var frames: [256]Frame = undefined;
    while (true) {
        const done = !player.render(&frames);
        if (c.ma_encoder_write_pcm_frames(&encoder, &frames, frames.len, null) != c.MA_SUCCESS) {
            return error.AudioError;
        }
        if (done) break;
    }
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
    args: std.process.Args.Iterator,
    state: union(enum) {
        normal,
        short: []const u8,
        long: struct {
            option: []const u8,
            value: []const u8,
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

    fn init(args: std.process.Args.Iterator) ArgIterator {
        return .{
            .args = args,
            .state = .normal,
        };
    }

    fn deinit(iter: *ArgIterator) void {
        iter.args.deinit();
        iter.* = undefined;
    }

    fn next(iter: *ArgIterator) ?Arg {
        switch (iter.state) {
            .normal => {
                const arg = iter.args.next() orelse return null;
                if (std.mem.eql(u8, arg, "--")) {
                    iter.state = .params_only;
                    return .{ .param = iter.args.next() orelse return null };
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
            .params_only => return .{ .param = iter.args.next() orelse return null },
        }
    }

    fn optionValue(iter: *ArgIterator) ?[]const u8 {
        switch (iter.state) {
            .normal => return iter.args.next(),
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
};

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const log = std.log;
const zfm = @import("zfm");
const Frame = zfm.Frame;
const Driver = zfm.Driver;
const Synth = zfm.Synth;
const Module = zfm.Module;
const Compiler = zfm.Compiler;
const c = @import("c");
