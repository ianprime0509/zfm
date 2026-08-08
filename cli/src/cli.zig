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

    if (std.ascii.endsWithIgnoreCase(input_path, ".ff")) {
        const output_path = maybe_output_path orelse fatal("missing output file", .{});
        if (!std.mem.endsWith(u8, output_path, ".zfm")) fatal("invalid output file for bank", .{});
        try convertPmdBank(gpa, io, input_path, output_path);
        return;
    }

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

fn convertPmdBank(gpa: Allocator, io: Io, input_path: []const u8, output_path: []const u8) !void {
    var input_file = try std.Io.Dir.cwd().openFile(io, input_path, .{});
    defer input_file.close(io);
    var output_file = try std.Io.Dir.cwd().createFile(io, output_path, .{});
    defer output_file.close(io);

    var reader_buf: [1024]u8 = undefined;
    var reader = input_file.reader(io, &reader_buf);
    var writer_buf: [1024]u8 = undefined;
    var writer = output_file.writer(io, &writer_buf);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var name_bytes: std.ArrayList(u8) = .empty;
    var seen_names: std.array_hash_map.String(void) = .empty;

    while (true) {
        const pmd_patch = PmdPatch.read(&reader.interface) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.EndOfStream => break,
        };

        const raw_name = pmd_patch.name();
        // The PMD bank format is just a dump of internal instrument data, including uninitialized entries.
        // These uninitialized entries can be identified because they have no name; just skip them.
        if (raw_name.len == 0) continue;
        const name_start = name_bytes.items.len;
        try escapePatchName(arena, &name_bytes, raw_name);
        const name_prefix_end = name_bytes.items.len;
        var counter: u32 = 2;
        while (seen_names.contains(name_bytes.items[name_start..])) : (counter += 1) {
            name_bytes.items.len = name_prefix_end;
            try name_bytes.print(arena, "-{}", .{counter});
        }
        const name = name_bytes.items[name_start..];
        try seen_names.put(arena, name, {});

        try writer.interface.print("@{s} {s}.\n", .{ name, switch (pmd_patch.alg) {
            0 => "0 1 2 3",
            1 => "0 2 3, 1 2",
            2 => "0 3, 1 2 3",
            3 => "0 1 3, 2 3",
            4 => "0 1, 2 3",
            5 => "0 1, 0 2, 0 3",
            6 => "0 1, 2, 3",
            7 => "0, 1, 2, 3",
        } });
        for (pmd_patch.slots, 0..) |slot, i| {
            const carrier = pmd_patch.isCarrier(@intCast(i));
            // Detune and amplitude modulation have no synth equivalent.
            // The synth's per-sample phase is in cycles (multiplied by tau
            // only inside the oscillator), so the modulator's radian phase
            // deviation and the feedback term are divided by tau.
            const tl = Opn.tlLinear(slot.tl) * (if (carrier) 1.0 else Opn.pm_scale / std.math.tau);
            const ml = Opn.multiple(slot.multi);
            const fb = if (i == 0) Opn.feedback(pmd_patch.fb, carrier) / std.math.tau else 0.0;
            const env = Opn.envelope(slot);
            try writer.interface.print("  sine {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
                tl,
                ml,
                fb,
                env.ar,
                env.dr,
                env.sl,
                env.sr,
                env.rr,
            });
        }
        try writer.interface.print("\n", .{});
    }

    try writer.interface.flush();
}

fn escapePatchName(gpa: Allocator, bytes: *std.ArrayList(u8), raw_name: []const u8) !void {
    for (raw_name) |b| {
        try bytes.append(gpa, switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => b,
            else => '_',
        });
    }
}

/// Approximate conversions from YM2608 (OPNA) parameters to synth
/// parameters. The envelope model and increment table follow the ymfm
/// emulator, validated against it empirically.
const Opn = struct {
    /// FM clock at the nominal 8 MHz master clock: 8 MHz / (6 * 24).
    const fm_clock = 8_000_000.0 / 144.0;
    /// The envelope generator clocks once every 3 FM clocks.
    const eg_clock = fm_clock / 3.0;
    /// dB per envelope attenuation unit (0.75 dB / 8).
    const atten_db = 0.09375;
    /// Key scaling makes envelope rates note-dependent; approximate it at
    /// a fixed mid-range key code (block 4, around A440).
    const ref_keycode: u32 = 16;
    /// Envelope fall covered by the synth's sustain and release times
    /// (Envelope.silence is 1e-4, i.e. -80 dB).
    const silence_db = 80.0;

    /// Peak phase deviation in radians of a full-scale (TL=0) modulator:
    /// its 13-bit magnitude output is halved, then added to the 10-bit
    /// (tau = 1024 units) carrier phase.
    const pm_scale: f32 = 8191.0 / 2048.0 * std.math.tau;

    /// Attenuation increments for each 6-bit envelope rate, packed as
    /// eight 4-bit values indexed by the step counter (ymfm's
    /// attenuation_increment table).
    const increment_table: [64]u32 = .{
        0x00000000, 0x00000000, 0x10101010, 0x10101010,
        0x10101010, 0x10101010, 0x11101110, 0x11101110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x10101010, 0x10111010, 0x11101110, 0x11111110,
        0x11111111, 0x21112111, 0x21212121, 0x22212221,
        0x22222222, 0x42224222, 0x42424242, 0x44424442,
        0x44444444, 0x84448444, 0x84848484, 0x88848884,
        0x88888888, 0x88888888, 0x88888888, 0x88888888,
    };

    fn increment(rate: u32, index: u32) u32 {
        return (increment_table[rate] >> @intCast(4 * index)) & 0xf;
    }

    /// 6-bit envelope rate for a raw register rate, including the key
    /// scaling offset at the reference key code. Raw rate 0 never
    /// advances, regardless of key scaling.
    fn effectiveRate(raw: u32, ks: u3) u32 {
        if (raw == 0) return 0;
        return @min(raw + (ref_keycode >> @as(u5, ks ^ 3)), 63);
    }

    fn tlLinear(tl: u7) f32 {
        // TL steps are 0.75 dB.
        return std.math.pow(f32, 10.0, -0.0375 * @as(f32, @floatFromInt(tl)));
    }

    fn multiple(multi: u4) f32 {
        // MULTI 0 means 0.5.
        return if (multi == 0) 0.5 else @floatFromInt(multi);
    }

    fn feedback(fb: u3, carrier: bool) f32 {
        if (fb == 0) return 0.0;
        // The feedback register shifts the operator's own 14-bit output
        // into its 10-bit phase by (9 - fb), wrapping to 2^(fb-8) once
        // expressed per unit of modulator output in the synth; modulator
        // outputs carry the pm_scale factor, carrier outputs don't.
        const scale = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(fb)) - 8.0);
        return scale * (if (carrier) pm_scale else 1.0);
    }

    /// Approximate attack duration in seconds: the time for the envelope
    /// attenuation to fall from maximum to 1.5 dB, following ymfm's
    /// envelope algorithm. Rates 62+ attack instantly; rates below 4
    /// never advance, which the synth expresses as a held (silent)
    /// attack, matching the hardware.
    fn attackTime(rate: u32) f32 {
        if (rate < 4) return 0.0;
        if (rate >= 62) return zfm.sample_time;
        const rate_shift: u5 = @intCast(rate >> 2);
        var atten: u32 = 0x3ff;
        var counter: u32 = 0;
        var ticks: u32 = 0;
        // Every rate >= 4 has a non-zero increment at least every eighth
        // step, so the attenuation strictly decreases until the loop
        // condition is met.
        while (atten > 16) {
            counter +%= 1;
            ticks += 1;
            const shifted = counter << rate_shift;
            if (shifted & 0x7ff != 0) continue;
            const index = if (rate_shift <= 11) (shifted >> 11) & 7 else (shifted >> rate_shift) & 7;
            atten -|= ((atten + 1) * increment(rate, index) + 15) >> 4;
        }
        return @as(f32, @floatFromInt(ticks)) / eg_clock;
    }

    /// Average attenuation rate in dB per second of the decay, sustain
    /// and release phases at the given 6-bit rate.
    fn decayDbPerSec(rate: u32) f32 {
        if (rate < 4) return 0.0;
        var total: u32 = 0;
        for (0..8) |i| total += increment(rate, @intCast(i));
        const avg = @as(f32, @floatFromInt(total)) / 8.0;
        // Steps happen once every 2^(11 - rate_shift) EG clocks.
        const rate_shift: f32 = @floatFromInt(@min(rate >> 2, 11));
        return avg * eg_clock * std.math.pow(f32, 2.0, rate_shift - 11.0) * atten_db;
    }

    fn sustainDb(sl: u4) f32 {
        // SL steps are 3 dB, except SL 15 which means 93 dB.
        return if (sl == 15) 93.0 else 3.0 * @as(f32, @floatFromInt(sl));
    }

    const EnvTimes = struct { ar: f32, dr: f32, sl: f32, sr: f32, rr: f32 };

    fn envelope(slot: PmdPatch.Slot) EnvTimes {
        const sustain_db = sustainDb(slot.sl);
        const dr_rate = decayDbPerSec(effectiveRate(2 * @as(u32, slot.dr), slot.ks));
        const sr_rate = decayDbPerSec(effectiveRate(2 * @as(u32, slot.sr), slot.ks));
        const rr_rate = decayDbPerSec(effectiveRate(4 * @as(u32, slot.rr) + 2, slot.ks));
        return .{
            .ar = attackTime(effectiveRate(2 * @as(u32, slot.ar), slot.ks)),
            .dr = if (dr_rate > 0.0) sustain_db / dr_rate else 0.0,
            .sl = std.math.pow(f32, 10.0, -sustain_db / 20.0),
            .sr = if (sr_rate > 0.0) silence_db / sr_rate else 0.0,
            .rr = if (rr_rate > 0.0) silence_db / rr_rate else 0.0,
        };
    }
};

const PmdPatch = struct {
    name_buf: [7]u8,
    fb: u3,
    alg: u3,
    slots: [4]Slot,

    const Slot = struct {
        multi: u4,
        dt: i3,
        tl: u7,
        ks: u3,
        ar: u5,
        am: u1,
        dr: u5,
        sr: u5,
        sl: u4,
        rr: u4,
    };

    const FbAlg = packed struct(u8) {
        alg: u3,
        fb: u3,
        _unused: u2,
    };

    const DtMulti = packed struct(u8) {
        multi: u4,
        raw_dt: packed struct(u3) {
            abs: u2,
            sign: bool,
        },
        _unused: u1,

        fn dt(dt_multi: DtMulti) i3 {
            const raw_dt = dt_multi.raw_dt;
            return if (raw_dt.sign) -@as(i3, raw_dt.abs) else raw_dt.abs;
        }
    };

    const Tl = packed struct(u8) {
        tl: u7,
        _unused: u1,
    };

    const KsAr = packed struct(u8) {
        ar: u5,
        _unused: u1,
        ks: u2,
    };

    const AmDr = packed struct(u8) {
        dr: u5,
        _unused: u2,
        am: u1,
    };

    const Sr = packed struct(u8) {
        sr: u5,
        _unused: u3,
    };

    const SlRr = packed struct(u8) {
        rr: u4,
        sl: u4,
    };

    fn read(reader: *Reader) !PmdPatch {
        const raw = try reader.take(32);
        var patch: PmdPatch = undefined;
        patch.name_buf = raw[25..][0..7].*;
        const fb_alg: FbAlg = @bitCast(raw[24]);
        patch.fb = fb_alg.fb;
        patch.alg = fb_alg.alg;
        const slots: [4]*Slot = .{ &patch.slots[0], &patch.slots[2], &patch.slots[1], &patch.slots[3] };
        // DT/MULTI
        for (slots, 0..) |slot, i| {
            const dt_multi: DtMulti = @bitCast(raw[i]);
            slot.multi = dt_multi.multi;
            slot.dt = dt_multi.dt();
        }
        // TL
        for (slots, 0..) |slot, i| {
            const tl: Tl = @bitCast(raw[4 + i]);
            slot.tl = tl.tl;
        }
        // KS/AR
        for (slots, 0..) |slot, i| {
            const ks_ar: KsAr = @bitCast(raw[8 + i]);
            slot.ks = ks_ar.ks;
            slot.ar = ks_ar.ar;
        }
        // AM/DR
        for (slots, 0..) |slot, i| {
            const am_dr: AmDr = @bitCast(raw[12 + i]);
            slot.am = am_dr.am;
            slot.dr = am_dr.dr;
        }
        // SR
        for (slots, 0..) |slot, i| {
            const sr: Sr = @bitCast(raw[16 + i]);
            slot.sr = sr.sr;
        }
        // SL/RR
        for (slots, 0..) |slot, i| {
            const sl_rr: SlRr = @bitCast(raw[20 + i]);
            slot.sl = sl_rr.sl;
            slot.rr = sl_rr.rr;
        }
        return patch;
    }

    fn name(patch: *const PmdPatch) []const u8 {
        return std.mem.sliceTo(&patch.name_buf, 0);
    }

    fn isCarrier(patch: *const PmdPatch, slot: u2) bool {
        const carriers: u4 = switch (patch.alg) {
            0, 1, 2, 3 => 0b1000,
            4 => 0b1010,
            5, 6 => 0b1110,
            7 => 0b1111,
        };
        return carriers & (@as(u4, 1) << slot) != 0;
    }
};

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

    if (!std.unicode.utf8ValidateSlice(source)) {
        log.err("invalid UTF-8 in input", .{});
        return error.CompileError;
    }

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
const Reader = Io.Reader;
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
