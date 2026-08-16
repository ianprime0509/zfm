//! A wrapper around a `Driver` that applies a maximum loop count and optional
//! fade-out.

driver: *Driver,
options: Options,
volume: f32,

pub const Options = struct {
    loops: u8 = 1,
    fade: bool = true,
};

const fade_speed = 0.00001;

pub fn init(driver: *Driver, options: Options) Player {
    return .{
        .driver = driver,
        .options = options,
        .volume = 1.0,
    };
}

pub fn ended(player: *const Player) bool {
    return for (player.driver.parts) |part| {
        if (!part.ended and part.cycle < player.options.loops) break false;
    } else true;
}

pub fn render(player: *Player, frames: []Frame) bool {
    for (frames) |*frame| {
        const FrameVec = @Vector(2, f32);
        frame.* = @as(FrameVec, @splat(player.volume)) * @as(FrameVec, player.driver.sample());
        if (player.ended()) {
            player.volume = if (player.options.fade) @max(0.0, player.volume - fade_speed) else 0.0;
        }
    }
    return player.volume > 0.0;
}

/// Renders and discards all remaining player output. Asserts that the module
/// being played doesn't have any infinite loops.
pub fn drain(player: *Player) void {
    assert(!player.driver.mod.hasInfiniteLoop());

    var frames: [256]Frame = undefined;
    while (player.render(&frames)) {}
}

/// Renders all remaining player output to a WAV file. Asserts that the module
/// being played doesn't have any infinite loops.
pub fn renderToWav(player: *Player, writer: *Io.File.Writer) (Writer.Error || Io.File.SeekError)!void {
    assert(!player.driver.mod.hasInfiniteLoop());

    const channels: u16 = 2;
    const bits_per_sample: u16 = @bitSizeOf(f32);
    const block_align = channels * @sizeOf(f32);
    const byte_rate = zfm.sample_rate * @as(u32, block_align);

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

    try writer.seekTo(4);
    try writer.interface.writeInt(u32, @intCast(36 + data_bytes), .little);
    try writer.seekTo(40);
    try writer.interface.writeInt(u32, @intCast(data_bytes), .little);
}

const Player = @This();

const std = @import("std");
const Io = std.Io;
const Writer = Io.Writer;
const assert = std.debug.assert;
const zfm = @import("./zfm.zig");
const Frame = zfm.Frame;
const Synth = zfm.Synth;
const Module = zfm.Module;
const Driver = zfm.Driver;
