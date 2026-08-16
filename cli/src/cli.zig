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
    var maybe_output_path: ?[]const u8 = null;
    var maybe_log_path: ?[]const u8 = null;
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
            } else if (option.is(null, "log-file")) {
                if (!debug_features) fatal("--log-file is only available in debug builds", .{});
                maybe_log_path = args.optionValue() orelse fatal("missing value for --log-file", .{});
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

    if (std.ascii.endsWithIgnoreCase(input_path, ".ff")) {
        const output_path = maybe_output_path orelse fatal("missing output file", .{});
        if (!std.mem.endsWith(u8, output_path, ".zfm")) fatal("invalid output file for bank", .{});
        try convertPmdBank(gpa, io, input_path, output_path);
        return;
    }

    var mod = try readInput(gpa, io, input_path);
    defer mod.deinit(gpa);

    try printPartLengths(gpa, &mod);

    const voices = try gpa.alloc(Synth.Voice, mod.parts.len);
    defer gpa.free(voices);
    const slots = try gpa.alloc(Synth.Slot, mod.parts.len * Synth.Voice.n_slots);
    defer gpa.free(slots);
    var synth: Synth = .init(voices, slots, Synth.default_volume);

    const parts = try gpa.alloc(Driver.Part, mod.parts.len);
    defer gpa.free(parts);
    var driver: Driver = .init(&synth, &mod, parts);
    var player: Player = .init(&driver, options);

    const maybe_log_file: ?Io.File = if (maybe_log_path) |log_path| try Io.Dir.cwd().createFile(io, log_path, .{}) else null;
    defer if (maybe_log_file) |log_file| log_file.close(io);
    var log_buf: [1024]u8 = undefined;
    var maybe_log_writer: ?Io.File.Writer = if (maybe_log_file) |log_file| log_file.writer(io, &log_buf) else null;
    var maybe_logging_hooks: ?Driver.LoggingHooks = if (maybe_log_writer) |*log_writer| .init(&log_writer.interface) else null;
    if (maybe_logging_hooks) |*logging_hooks| player.driver.hooks = logging_hooks.hooks();

    if (maybe_output_path) |output_path| {
        try mainSave(gpa, io, &player, output_path);
    } else {
        try mainPlay(io, &player);
    }
}

fn convertPmdBank(gpa: Allocator, io: Io, input_path: []const u8, output_path: []const u8) !void {
    var input_file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var output_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);

    var reader_buf: [1024]u8 = undefined;
    var reader = input_file.reader(io, &reader_buf);
    var writer_buf: [1024]u8 = undefined;
    var writer = output_file.writer(io, &writer_buf);

    try zfm.convert.pmd.toZfm(gpa, &reader.interface, &writer.interface);

    try writer.interface.flush();
}

fn readInput(gpa: Allocator, io: Io, path: []const u8) !Module {
    if (std.mem.endsWith(u8, path, ".zfm")) {
        return try readInputZfm(gpa, io, path);
    } else if (std.mem.endsWith(u8, path, ".mod")) {
        if (!debug_features) fatal("module format is not stable/portable and is only available in debug builds", .{});
        return try readInputMod(gpa, io, path);
    } else {
        fatal("unknown input file type", .{});
    }
}

fn readInputZfm(gpa: Allocator, io: Io, path: []const u8) !Module {
    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .@"1", 0);
    defer gpa.free(source);

    if (!std.unicode.utf8ValidateSlice(source)) {
        log.err("invalid UTF-8 in input", .{});
        return error.CompileError;
    }

    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();
    if (compiler.errors.items.len > 0) {
        for (compiler.errors.items) |err| {
            const loc = compiler.sourceLocation(err.span);
            if (err.part) |part| {
                log.err("{}:{}-{}:{}: part {c}: {f}", .{ loc.start.line, loc.start.column, loc.end.line, loc.end.column, part, err });
            } else {
                log.err("{}:{}-{}:{}: {f}", .{ loc.start.line, loc.start.column, loc.end.line, loc.end.column, err });
            }
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

fn printPartLengths(gpa: Allocator, mod: *const Module) !void {
    const PartLength = struct {
        name: u8,
        len: ?Module.PartLength,
    };

    const parts = try gpa.alloc(PartLength, mod.parts.len);
    defer gpa.free(parts);
    for (parts, mod.parts, 0..) |*part, mod_part, i| {
        part.name = mod_part.name;
        part.len = mod.calculatePartLength(@fromBackingInt(@intCast(i)));
    }
    std.sort.heap(PartLength, parts, {}, struct {
        fn lessThan(_: void, p1: PartLength, p2: PartLength) bool {
            return p1.name < p2.name;
        }
    }.lessThan);

    for (parts) |part| {
        if (part.len) |len| {
            if (len.loop) |loop_len| {
                log.info("Part {c}: {} ticks (loop: {} ticks)", .{ part.name, @backingInt(len.total), @backingInt(loop_len) });
            } else {
                log.info("Part {c}: {} ticks", .{ part.name, @backingInt(len.total) });
            }
        } else {
            log.info("Part {c}: infinite loop", .{part.name});
        }
    }
}

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

fn mainSave(gpa: Allocator, io: Io, player: *Player, path: []const u8) !void {
    if (player.driver.mod.hasInfiniteLoop()) fatal("cannot render WAV with infinite loop", .{});

    if (std.mem.endsWith(u8, path, ".wav")) {
        try saveWav(io, player, path);
    } else if (std.mem.endsWith(u8, path, ".mod")) {
        if (!debug_features) fatal("module format is not stable/portable and is only available in debug builds", .{});
        try saveMod(gpa, io, player, path);
    } else if (std.mem.endsWith(u8, path, ".json")) {
        if (!debug_features) fatal("JSON output format is only available in debug builds", .{});
        try saveJson(io, player, path);
    } else {
        fatal("unknown output file type", .{});
    }
}

fn saveWav(io: Io, player: *Player, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try player.renderToWav(&writer);
    try writer.interface.flush();
}

fn saveMod(gpa: Allocator, io: Io, player: *Player, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try player.driver.mod.dump(gpa, &writer.interface);
    try writer.interface.flush();
    // Although we're not saving the player output, we need to drain it in case
    // a log file is being used.
    player.drain();
}

fn saveJson(io: Io, player: *Player, path: []const u8) !void {
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try player.driver.mod.dumpJson(&writer.interface);
    try writer.interface.flush();
    // Although we're not saving the player output, we need to drain it in case
    // a log file is being used.
    player.drain();
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
const Reader = Io.Reader;
const Writer = Io.Writer;
const assert = std.debug.assert;
const log = std.log;
const zfm = @import("zfm");
const Sample = zfm.Sample;
const Frame = zfm.Frame;
const Driver = zfm.Driver;
const Synth = zfm.Synth;
const Module = zfm.Module;
const Ticks = Module.Ticks;
const Compiler = zfm.Compiler;
const Player = zfm.Player;
const c = @import("c");
