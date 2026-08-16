//! Conversions from PMD (Professional Music Driver) by KAJA for the PC-98 (YM2608).

pub const Patch = struct {
    name_buf: [7]u8,
    fb: u3,
    alg: u3,
    slots: [4]Slot,

    pub const Slot = struct {
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

    pub const FbAlg = packed struct(u8) {
        alg: u3,
        fb: u3,
        _unused: u2,
    };

    pub const DtMulti = packed struct(u8) {
        multi: u4,
        raw_dt: packed struct(u3) {
            abs: u2,
            sign: bool,
        },
        _unused: u1,

        pub fn dt(dt_multi: DtMulti) i3 {
            const raw_dt = dt_multi.raw_dt;
            return if (raw_dt.sign) -@as(i3, raw_dt.abs) else raw_dt.abs;
        }
    };

    pub const Tl = packed struct(u8) {
        tl: u7,
        _unused: u1,
    };

    pub const KsAr = packed struct(u8) {
        ar: u5,
        _unused: u1,
        ks: u2,
    };

    pub const AmDr = packed struct(u8) {
        dr: u5,
        _unused: u2,
        am: u1,
    };

    pub const Sr = packed struct(u8) {
        sr: u5,
        _unused: u3,
    };

    pub const SlRr = packed struct(u8) {
        rr: u4,
        sl: u4,
    };

    pub const Reader = struct {
        reader: *Io.Reader,

        pub fn read(reader: *Reader) Io.Reader.ShortError!?Patch {
            while (true) {
                const raw = reader.reader.take(32) catch |err| switch (err) {
                    error.EndOfStream => return null,
                    error.ReadFailed => return error.ReadFailed,
                };

                var patch: Patch = undefined;

                patch.name_buf = raw[25..][0..7].*;
                // The PMD bank format is just a dump of internal instrument data,
                // including uninitialized entries. These uninitialized entries can
                // be identified because they have no name; just skip them.
                if (patch.name_buf[0] == 0) continue;

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
        }
    };

    pub fn name(patch: *const Patch) []const u8 {
        return std.mem.sliceTo(&patch.name_buf, 0);
    }

    pub fn isCarrier(patch: *const Patch, slot: u2) bool {
        const carriers: u4 = switch (patch.alg) {
            0, 1, 2, 3 => 0b1000,
            4 => 0b1010,
            5, 6 => 0b1110,
            7 => 0b1111,
        };
        return carriers & (@as(u4, 1) << slot) != 0;
    }

    pub fn writeZfm(patch: *const Patch, writer: *Io.Writer, patch_name: []const u8) Io.Writer.Error!void {
        try writer.print("@{s} {s}.\n", .{ patch_name, switch (patch.alg) {
            0 => "0 1 2 3",
            1 => "0 2 3, 1 2",
            2 => "0 3, 1 2 3",
            3 => "0 1 3, 2 3",
            4 => "0 1, 2 3",
            5 => "0 1, 0 2, 0 3",
            6 => "0 1, 2, 3",
            7 => "0, 1, 2, 3",
        } });
        for (patch.slots, 0..) |slot, i| {
            const carrier = patch.isCarrier(@intCast(i));
            // Detune and amplitude modulation have no synth equivalent.
            // The synth's per-sample phase is in cycles (multiplied by tau
            // only inside the oscillator), so the modulator's radian phase
            // deviation and the feedback term are divided by tau.
            const tl = Opn.tlLinear(slot.tl) * (if (carrier) 1.0 else Opn.pm_scale / std.math.tau);
            const ml = Opn.multiple(slot.multi);
            const fb = if (i == 0) Opn.feedback(patch.fb, carrier) / std.math.tau else 0.0;
            const env = Opn.envelope(slot);
            try writer.print("  sin {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
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
    }
};

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

    fn envelope(slot: Patch.Slot) EnvTimes {
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

pub const ToZfmError = Allocator.Error || Io.Reader.ShortError || Io.Writer.Error;

pub fn toZfm(gpa: Allocator, reader: *Io.Reader, writer: *Io.Writer) ToZfmError!void {
    var names: StringPool = .empty;
    defer names.deinit(gpa);

    var patch_reader: Patch.Reader = .{ .reader = reader };
    while (try patch_reader.read()) |patch| {
        var name_buf: [64]u8 = undefined; // Raw names are at most 7 characters, so this is more than enough.
        var name_writer: Io.Writer = .fixed(&name_buf);
        escapePatchName(&name_writer, patch.name()) catch unreachable; // The buffer is long enough.
        const name_prefix_end = name_writer.end;
        var counter: u32 = 2;
        while (names.find(name_writer.buffered()) != null) : (counter += 1) {
            name_writer.end = name_prefix_end;
            name_writer.print("-{}", .{counter}) catch unreachable; // The buffer is long enough.
        }
        const name = name_writer.buffered();
        _ = try names.intern(gpa, name);

        try patch.writeZfm(writer, name);

        try writer.print("\n", .{});
    }
}

fn escapePatchName(writer: *Io.Writer, raw_name: []const u8) !void {
    for (raw_name) |b| {
        try writer.writeByte(switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => b,
            else => '_',
        });
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const zfm = @import("../zfm.zig");
const StringPool = @import("../StringPool.zig");
