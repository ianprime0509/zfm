const gpa = std.heap.wasm_allocator;

var synth: Synth = .init(&.{}, &.{}, 0.0);
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
    .elapsed_ticks = .zero,
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
    try mod_commands.append(gpa, .{
        .tag = .end,
        .data = .{ .none = {} },
        .span = undefined,
        .skipped = false,
    });
    const end: Command.Index = @fromBackingInt(0);

    const mod_parts = try gpa.alloc(Module.Part, n_voices);
    errdefer gpa.free(mod_parts);
    @memset(mod_parts, .{ .name = 0, .start = end, .global_loop = end });

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
    synth = .init(voices, slots, Synth.default_volume);

    parts = try gpa.alloc(Driver.Part, mod.parts.len);
    driver = .init(&synth, &mod, parts);
}

fn clear() void {
    synth = .init(&.{}, &.{}, 0.0);
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

export fn setPatch(voice: Voice.Index) void {
    setPatchInner(voice) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        else => log.err("invalid patch JSON: {t}", .{err}),
    };
}

fn setPatchInner(voice: Voice.Index) !void {
    const wire = try std.json.parseFromSlice(WirePatch, gpa, transfer.items, .{});
    defer wire.deinit();
    driver.setPatch(voice, wire.value.toPatch());
}

export fn setLfoEnabled(voice: Voice.Index, index: Lfo.Index, enabled: bool) void {
    driver.setLfoEnabled(voice, index, enabled);
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

export fn transferCurrentCommandSpans() void {
    transferCurrentCommandSpansInner() catch @panic("OOM");
}

fn transferCurrentCommandSpansInner() (Allocator.Error || Writer.Error)!void {
    var writer: Writer.Allocating = .fromArrayList(gpa, &transfer);
    defer transfer = writer.toArrayList();
    writer.clearRetainingCapacity();
    var out: std.json.Stringify = .{ .writer = &writer.writer };

    try out.beginArray();
    for (driver.parts) |*part| {
        const command = part.executing_command;
        if (driver.mod.commandTag(command) == .end) {
            // `end` marks the end of the part's commands; it has no source
            // span to highlight, so signal that no command is executing.
            try out.write(null);
        } else {
            const span = driver.mod.commandSpan(command);
            try out.beginArray();
            try out.write(@backingInt(span.start));
            try out.write(@backingInt(span.end));
            try out.endArray();
        }
    }
    try out.endArray();
}

const WirePatch = struct {
    connections: [Voice.n_slots][Voice.n_slots]bool,
    slot_waves: [Voice.n_slots]Slot.Wave,
    slot_params: [Voice.n_slots]Slot.UserParams,
    slot_env_params: [Voice.n_slots]Envelope.UserParams,

    fn toPatch(wire: WirePatch) Patch {
        var connections: Voice.Connections = .none;
        for (wire.connections, 0..) |row, from| {
            for (row, 0..) |edge, to| {
                if (edge) connections.connect(@intCast(from), @intCast(to));
            }
        }
        return .{
            .connections = connections,
            .slot_waves = wire.slot_waves,
            .slot_params = wire.slot_params,
            .slot_env_params = wire.slot_env_params,
        };
    }
};

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
const Writer = Io.Writer;
const zfm = @import("zfm");
const Synth = zfm.Synth;
const Frame = zfm.Frame;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const Module = zfm.Module;
const Command = Module.Command;
const Patch = Module.Patch;
const Lfo = Module.Lfo;
const Driver = zfm.Driver;
