const gpa = std.heap.wasm_allocator;

var synth: Synth = .zero;
var voices: []Voice = &.{};
var slots: []Slot = &.{};

var mod: Module = .empty;
var parts: []Driver.Part = &.{};
var driver: Driver = .{
    .synth = &synth,
    .mod = &mod,
    .parts = &.{},
    .tick_delay = .zero,
    .lfo_delay = .zero,
    .tempo = .default,
};

var transfer: std.ArrayList(u8) = .empty;

export fn transferPtr() [*]u8 {
    return transfer.items.ptr;
}

export fn transferLen() usize {
    return transfer.items.len;
}

export fn transferSetLen(len: usize) void {
    transfer.ensureTotalCapacity(gpa, len) catch @panic("OOM");
    transfer.items.len = len;
}

export fn reset(n_voices: usize) void {
    resetInner(n_voices) catch @panic("OOM");
}

fn resetInner(n_voices: usize) Allocator.Error!void {
    try loadModule(try emptyModule(n_voices));
}

fn emptyModule(n_voices: usize) Allocator.Error!Module {
    var mod_commands: Command.List = .empty;
    errdefer mod_commands.deinit(gpa);
    try mod_commands.append(gpa, .{ .tag = .end, .data = .{ .none = {} } });
    const end: Command.Index = @fromBackingInt(0);

    const mod_parts = try gpa.alloc(Module.Part, n_voices);
    errdefer gpa.free(mod_parts);
    @memset(mod_parts, .{ .start = end, .global_loop = end });

    return .{
        .commands = mod_commands.toOwnedSlice(),
        .parts = mod_parts,
        .patches = &.{},
        .extra = .empty,
        .strings = .empty,

        .title = .empty,
        .composer = .empty,
        .arranger = .empty,
        .initial_tempo = .default,
    };
}

export fn load() void {
    loadInner() catch @panic("OOM");
}

fn loadInner() Allocator.Error!void {
    var reader: Reader = .fixed(transfer.items);
    const new_mod = Module.load(gpa, &reader) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => unreachable,
        // The module is assumed to be valid, as it was compiled by the compiler worker.
        error.EndOfStream => unreachable,
    };
    try loadModule(new_mod);
}

fn loadModule(new_mod: Module) Allocator.Error!void {
    clear();
    errdefer clear();

    mod = new_mod;

    voices = try gpa.alloc(Voice, mod.parts.len);
    slots = try gpa.alloc(Slot, mod.parts.len * Voice.n_slots);
    synth = .init(voices, slots, 0.2);

    parts = try gpa.alloc(Driver.Part, mod.parts.len);
    driver = .init(&synth, &mod, parts);
}

fn clear() void {
    synth = .zero;
    gpa.free(voices);
    voices = &.{};
    gpa.free(slots);
    slots = &.{};

    mod.deinit(gpa);
    mod = .empty;
    gpa.free(parts);
    parts = &.{};
    driver = .init(&synth, &mod, parts);
}

export fn keyOn(voice: Voice.Index, freq: f32) void {
    driver.keyOn(voice, freq);
}

export fn keyOff(voice: Voice.Index) void {
    driver.keyOff(voice);
}

export fn reconnect(voice: Voice.Index, connections: Voice.Connections.Packed) bool {
    return if (driver.reconnect(voice, .fromPacked(connections)))
        true
    else |err| switch (err) {
        error.Cycle => false,
    };
}

export fn setSlotParams(voice: Voice.Index, slot: u8, tl: f32, ml: f32, fb: f32, ws: f32) void {
    driver.setSlotParams(voice, @intCast(slot), .{
        .tl = tl,
        .ml = ml,
        .fb = fb,
        .ws = ws,
    });
}

export fn setSlotWave(voice: Voice.Index, slot: u8, wave: Slot.Wave) void {
    driver.setSlotWave(voice, @intCast(slot), wave);
}

export fn setSlotEnvParams(voice: Voice.Index, slot: u8, ar: f32, dr: f32, sl: f32, sr: f32, rr: f32) void {
    driver.setSlotEnvParams(voice, @intCast(slot), .{
        .ar = ar,
        .dr = dr,
        .sl = sl,
        .sr = sr,
        .rr = rr,
    });
}

export fn enableLfo(voice: Voice.Index, index: Lfo.Index) void {
    driver.enableLfo(voice, index);
}

export fn disableLfo(voice: Voice.Index, index: Lfo.Index) void {
    driver.disableLfo(voice, index);
}

export fn setLfoParams(voice: Voice.Index, index: Lfo.Index) void {
    setLfoParamsInner(voice, index) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => log.err("invalid LFO JSON: {t}", .{err}),
    };
}

fn setLfoParamsInner(voice: Voice.Index, index: Lfo.Index) !void {
    const params = try std.json.parseFromSlice(Lfo, gpa, transfer.items, .{});
    defer params.deinit();
    driver.setLfoParams(voice, index, params.value);
}

var render_buf: [256]Frame = undefined;

export fn ptrRenderBuf() *[256]Frame {
    return &render_buf;
}

export fn render(n: usize) void {
    for (render_buf[0..n]) |*f| f.* = driver.sample();
}

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
    consoleLog(@backingInt(level), msg.ptr, msg.len);
}

const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const zfm = @import("zfm");
const Synth = zfm.Synth;
const Frame = zfm.Frame;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Module = zfm.Module;
const Command = Module.Command;
const Lfo = Module.Lfo;
const Driver = zfm.Driver;
