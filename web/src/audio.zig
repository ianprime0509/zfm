pub const std_options: std.Options = .{
    .logFn = logFn,
};

extern fn consoleLog(level: u8, msg_ptr: [*]const u8, msg_len: usize) void;

fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [1024]u8 = undefined;
    const msg: []const u8 = std.fmt.bufPrint(&buf, "({t}) " ++ format, .{scope} ++ args) catch &buf;
    consoleLog(@intFromEnum(level), msg.ptr, msg.len);
}

const gpa = std.heap.wasm_allocator;

var synth: Synth = .zero;
var voices: []Voice = &.{};
var slots: []Slot = &.{};

export fn init(n_voices: usize) void {
    synth = .zero;
    gpa.free(voices);
    voices = &.{};
    gpa.free(slots);
    slots = &.{};

    voices = gpa.alloc(Voice, n_voices) catch @panic("OOM");
    slots = gpa.alloc(Slot, n_voices * Voice.n_slots) catch @panic("OOM");
    synth = .init(voices, slots, 0.2);
}

export fn keyOn(voice: Voice.Index) void {
    synth.keyOn(voice);
}

export fn keyOff(voice: Voice.Index) void {
    synth.keyOff(voice);
}

const max_connections = Voice.n_slots * Voice.n_slots;
var connections_buf: [max_connections][2]Voice.SlotIndex = undefined;

export fn ptrConnectionsBuf() *[max_connections][2]Voice.SlotIndex {
    return &connections_buf;
}

export fn reconnect(voice: Voice.Index, n_connections: usize) bool {
    return if (synth.voices[@intFromEnum(voice)].reconnect(.fromPairs(connections_buf[0..n_connections])))
        true
    else |err| switch (err) {
        error.Cycle => false,
    };
}

export fn setFreq(voice: Voice.Index, freq: f32) void {
    synth.voicePtr(voice).params.freq = freq;
}

export fn setSlotParams(voice: Voice.Index, slot: u8, tl: f32, ml: f32, fb: f32) void {
    synth.voiceSlotPtr(voice, @intCast(slot)).params = .{
        .tl = tl,
        .ml = ml,
        .fb = fb,
    };
}

export fn setSlotEnvParams(voice: Voice.Index, slot: u8, ar: f32, dr: f32, sl: f32, sr: f32, rr: f32) void {
    synth.voiceSlotPtr(voice, @intCast(slot)).env.params = .{
        .ar = ar,
        .dr = dr,
        .sl = sl,
        .sr = sr,
        .rr = rr,
    };
}

var render_buf: [256]Frame = undefined;

export fn ptrRenderBuf() *[256]Frame {
    return &render_buf;
}

export fn render(n: usize) void {
    for (render_buf[0..n]) |*f| f.* = synth.sample();
}

const std = @import("std");
const zfm = @import("zfm");
const Synth = zfm.Synth;
const Frame = zfm.Frame;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
