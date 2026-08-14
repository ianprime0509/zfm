const gpa = std.heap.wasm_allocator;

var source: [:0]const u8 = "";
var mod: Module = .empty;
var errors: std.ArrayList(Compiler.Error) = .empty;
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

export fn compile() bool {
    return compileInner() catch @panic("OOM");
}

fn compileInner() Allocator.Error!bool {
    if (source.len > 0) gpa.free(source);
    source = "";
    mod.deinit(gpa);
    mod = .empty;

    source = if (transfer.items.len > 0) try gpa.dupeSentinel(u8, transfer.items, 0) else "";
    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();

    errors.clearRetainingCapacity();
    try errors.appendSlice(gpa, compiler.errors.items);
    if (errors.items.len > 0) return false;

    mod = try compiler.toModule();
    return true;
}

export fn transferErrors() void {
    transferErrorsInner() catch @panic("OOM");
}

fn transferErrorsInner() (Allocator.Error || Writer.Error)!void {
    var writer: Writer.Allocating = .fromArrayList(gpa, &transfer);
    defer transfer = writer.toArrayList();
    writer.clearRetainingCapacity();
    var out: std.json.Stringify = .{ .writer = &writer.writer };

    try out.beginArray();
    for (errors.items) |err| {
        try out.beginObject();

        try out.objectField("message");
        var buf: [1024]u8 = undefined;
        const message = std.mem.print(&buf, "{f}", .{err}) catch message: {
            @memcpy(buf[buf.len - "...".len ..], "...");
            break :message &buf;
        };
        try out.write(message);

        // TODO: err.data

        try out.objectField("span");
        try out.beginObject();
        try out.objectField("start");
        try out.write(@backingInt(err.span.start));
        try out.objectField("end");
        try out.write(@backingInt(err.span.end));
        try out.endObject();

        if (err.part) |part| {
            try out.objectField("part");
            try out.write(@as([]const u8, &.{part}));
        }

        try out.endObject();
    }
    try out.endArray();
}

export fn transferPatches() void {
    transferPatchesInner() catch @panic("OOM");
}

fn transferPatchesInner() (Allocator.Error || Writer.Error)!void {
    var writer: Writer.Allocating = .fromArrayList(gpa, &transfer);
    defer transfer = writer.toArrayList();
    writer.clearRetainingCapacity();
    var out: std.json.Stringify = .{ .writer = &writer.writer };

    try out.beginArray();
    for (mod.patches) |entry| {
        const patch, _ = mod.extra.decode(Patch, entry.index);

        // The patch editor emits enabled LFOs as `; LFO preset:` comments
        // directly above the patch definition. Parse them back into LFO
        // state; LFOs without a preset comment keep their default state.
        var lfos: [n_user_lfos]LfoState = @splat(defaultLfoState());
        parseLfoPresets(entry.span.start, &lfos);

        try out.beginObject();

        try out.objectField("name");
        try out.write(mod.strings.string(entry.name));

        try out.objectField("connections");
        try out.beginObject();
        try out.objectField("edges");
        try out.beginArray();
        for (0..Voice.n_slots) |from| {
            try out.beginArray();
            for (0..Voice.n_slots) |to| {
                try out.write(patch.connections.deps[to].isSet(from));
            }
            try out.endArray();
        }
        try out.endArray();
        try out.endObject();

        try out.objectField("slotWaves");
        try out.write(patch.slot_waves);

        try out.objectField("slotParams");
        try out.write(patch.slot_params);

        try out.objectField("envParams");
        try out.write(patch.slot_env_params);

        try out.objectField("lfos");
        try out.write(lfos);

        try out.endObject();
    }
    try out.endArray();
}

const n_user_lfos = 4;

/// LFO state as transferred to the app, mirroring the editor's `LfoState`
/// and `LfoParams` types (core Module.Lfo).
const LfoState = struct {
    enabled: bool,
    params: LfoParams,
};

const LfoParams = struct {
    target: Lfo.Target,
    size: Lfo.Size,
    wave: Lfo.Wave,
    trigger: Lfo.Trigger,
    time_unit: Lfo.TimeUnit,
    adjust: bool,
};

fn defaultLfoState() LfoState {
    return .{
        .enabled = false,
        .params = .{
            .target = .freq,
            .size = .{ .scale = 5.0, .offset = 0.0 },
            .wave = .{ .sin = .{ .freq = 5.0 } },
            .trigger = .key_on,
            .time_unit = .seconds,
            .adjust = true,
        },
    };
}

/// Scan the lines directly above `patch_start` (the source offset of the `@`
/// that begins a patch definition) for `; LFO preset:` comments, parsing
/// each into `states`. Scanning stops at the first line that is not such a
/// comment, so stray comments elsewhere in the track are ignored.
fn parseLfoPresets(patch_start: SourceIndex, states: *[n_user_lfos]LfoState) void {
    var line_end = @backingInt(patch_start);
    while (line_end > 0) {
        // The previous line ends at `line_end - 1` (a line feed).
        var line_start = line_end - 1;
        while (line_start > 0 and source[line_start - 1] != '\n') line_start -= 1;
        const line = source[line_start..(line_end - 1)];
        line_end = line_start;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        const prefix = "; LFO preset:";
        if (!std.mem.startsWith(u8, trimmed, prefix)) break;
        parseLfoPreset(std.mem.trimStart(u8, trimmed[prefix.len..], " \t"), states);
    }
}

/// Parse the body of one `; LFO preset:` comment: whitespace-separated MML
/// LFO commands (MT/MS/MW/MO/MA) for a single LFO index, matching the form
/// the patch editor emits. Unmentioned parameters keep their defaults.
fn parseLfoPreset(content: []const u8, states: *[n_user_lfos]LfoState) void {
    var it = std.mem.tokenizeAny(u8, content, " \t");
    while (it.next()) |token| {
        if (token.len < 3 or token[0] != 'M') continue;
        const rest = token[2..];
        const comma = std.mem.findScalar(u8, rest, ',') orelse continue;
        const index = std.fmt.parseInt(u8, rest[0..comma], 10) catch continue;
        if (index >= n_user_lfos) continue;
        const args = rest[comma + 1 ..];
        const state = &states[index];
        switch (token[1]) {
            'T' => state.params.target = std.meta.stringToEnum(Lfo.Target, args) orelse continue,
            'S' => {
                var arg_it = std.mem.splitScalar(u8, args, ',');
                const scale = std.fmt.parseFloat(f32, arg_it.next() orelse continue) catch continue;
                const offset = std.fmt.parseFloat(f32, arg_it.next() orelse continue) catch continue;
                state.params.size = .{ .scale = scale, .offset = offset };
            },
            'W' => {
                var arg_it = std.mem.splitScalar(u8, args, ',');
                const wave_name = arg_it.next() orelse continue;
                if (std.mem.eql(u8, wave_name, "con")) {
                    state.params.wave = .con;
                } else if (std.mem.eql(u8, wave_name, "sin")) {
                    const freq = std.fmt.parseFloat(f32, arg_it.next() orelse continue) catch continue;
                    state.params.wave = .{ .sin = .{ .freq = freq } };
                } else if (std.mem.eql(u8, wave_name, "exp")) {
                    const mul = std.fmt.parseFloat(f32, arg_it.next() orelse continue) catch continue;
                    state.params.wave = .{ .exp = .{ .mul = mul } };
                } else continue;
            },
            'O' => state.params.trigger = std.meta.stringToEnum(Lfo.Trigger, args) orelse continue,
            'A' => {
                if (std.mem.eql(u8, args, "on")) {
                    state.params.adjust = true;
                } else if (std.mem.eql(u8, args, "off")) {
                    state.params.adjust = false;
                } else continue;
            },
            else => continue,
        }
        state.enabled = true;
    }
}

export fn transferModule() void {
    transferModuleInner() catch @panic("OOM");
}

fn transferModuleInner() (Allocator.Error || Writer.Error)!void {
    var writer: Writer.Allocating = .fromArrayList(gpa, &transfer);
    defer transfer = writer.toArrayList();
    writer.clearRetainingCapacity();
    try mod.dump(gpa, &writer.writer);
    try writer.writer.flush();
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
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const zfm = @import("zfm");
const Compiler = zfm.Compiler;
const Module = zfm.Module;
const Lfo = Module.Lfo;
const SourceIndex = Module.SourceIndex;
const Patch = Module.Patch;
const Synth = zfm.Synth;
const Voice = Synth.Voice;
