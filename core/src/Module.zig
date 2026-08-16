commands: Command.List.Slice,
parts: []Part,
patches: []Patch.Entry,
extra: Extra,
strings: StringPool.Slice,

title: StringPool.Index,
composer: StringPool.Index,
arranger: StringPool.Index,
initial_tempo: Tempo,

pub const empty: Module = .{
    .commands = .empty,
    .parts = &.{},
    .patches = &.{},
    .extra = .empty,
    .strings = .empty,

    .title = .empty,
    .composer = .empty,
    .arranger = .empty,
    .initial_tempo = .default,
};

pub fn deinit(mod: *Module, gpa: Allocator) void {
    mod.commands.deinit(gpa);
    gpa.free(mod.parts);
    gpa.free(mod.patches);
    mod.extra.deinit(gpa);
    mod.strings.deinit(gpa);
    mod.* = undefined;
}

pub fn commandTag(mod: *const Module, command: Command.Index) Command.Tag {
    return mod.commands.items(.tag)[@backingInt(command)];
}

pub fn commandData(mod: *const Module, command: Command.Index) Command.Data {
    return mod.commands.items(.data)[@backingInt(command)];
}

pub fn commandSpan(mod: *const Module, command: Command.Index) SourceIndex.Span {
    return mod.commands.items(.span)[@backingInt(command)];
}

pub fn commandSkipped(mod: *const Module, command: Command.Index) bool {
    return mod.commands.items(.skipped)[@backingInt(command)];
}

pub const PartLength = struct {
    total: Ticks,
    loop: ?Ticks,
};

/// Calculates the length of part `voice` in ticks. Returns null if there is an
/// infinite loop in the part.
pub fn calculatePartLength(mod: *const Module, voice: Voice.Index) ?PartLength {
    var ticks: Ticks = .zero;
    var loop_start_ticks: ?Ticks = null;
    const part = mod.parts[@backingInt(voice)];
    var command = part.start;
    var loops: Driver.Part.Loop.Stack = .empty;
    while (true) {
        const tag = mod.commandTag(command);
        if (tag == .end) break;
        if (command == part.global_loop and loop_start_ticks == null) loop_start_ticks = ticks;
        switch (tag) {
            .end => unreachable,
            .rest => {
                ticks = ticks.plus(mod.commandData(command).ticks);
                command = command.next();
            },
            .loop => {
                const loop = mod.commandData(command).loop;
                if (loop.count == .infinite) return null;
                if (loops.shouldLoop(command, loop.count)) {
                    command = command.offset(loop.branch);
                } else {
                    command = command.next();
                }
            },
            else => command = command.next(),
        }
    }
    return .{
        .total = ticks,
        .loop = if (loop_start_ticks) |start| ticks.minus(start) else null,
    };
}

// The approach taken for dump/save is exactly the same as what Zig does
// internally for its ZIR cache (see Zcu.zig, loadZirCache and saveZirCache).
// This is obviously unsafe and depends on compiler internals, but it's so
// efficient and nice...
const data_has_safety_tag = @sizeOf(Command.Data) != 8;
const DataBytes = [8]u8;
const HackDataLayout = extern struct {
    data: DataBytes align(@alignOf(Command.Data)),
    safety_tag: u8,
};
comptime {
    if (data_has_safety_tag) {
        assert(@sizeOf(HackDataLayout) == @sizeOf(Command.Data));
    }
}

const Header = extern struct {
    n_commands: u32,
    n_parts: u8,
    n_patches: u32,
    n_extra: u32,
    strings_len: u32,

    title: StringPool.Index,
    composer: StringPool.Index,
    arranger: StringPool.Index,
    initial_tempo_bpm: f32,
};

pub fn dump(mod: *const Module, gpa: Allocator, w: *Writer) (Writer.Error || Allocator.Error)!void {
    const header: Header = .{
        .n_commands = @intCast(mod.commands.len),
        .n_parts = @intCast(mod.parts.len),
        .n_patches = @intCast(mod.patches.len),
        .n_extra = @intCast(mod.extra.data.len),
        .strings_len = @intCast(mod.strings.bytes.len),

        .title = mod.title,
        .composer = mod.composer,
        .arranger = mod.arranger,
        .initial_tempo_bpm = mod.initial_tempo.bpm,
    };

    const safety_buffer = if (data_has_safety_tag)
        try gpa.alloc(DataBytes, mod.commands.len)
    else
        undefined;
    defer if (data_has_safety_tag) gpa.free(safety_buffer);
    if (data_has_safety_tag) {
        for (safety_buffer, mod.commands.items(.data)) |*data_bytes, *data| {
            const as_hack: *const HackDataLayout = @ptrCast(data);
            data_bytes.* = as_hack.data;
        }
    }

    var vecs = [_][]const u8{
        @ptrCast((&header)[0..1]),
        @ptrCast(mod.commands.items(.tag)),
        if (data_has_safety_tag)
            @ptrCast(safety_buffer)
        else
            @ptrCast(mod.commands.items(.data)),
        @ptrCast(mod.commands.items(.span)),
        @ptrCast(mod.commands.items(.skipped)),
        @ptrCast(mod.parts),
        @ptrCast(mod.patches),
        @ptrCast(mod.extra.data),
        mod.strings.bytes,
    };
    try w.writeVecAll(&vecs);
}

pub fn load(gpa: Allocator, r: *Reader) (Reader.Error || Allocator.Error)!Module {
    const header = (try r.takeStructPointer(Header)).*;

    var mod: Module = mod: {
        var commands: Command.List = .empty;
        defer commands.deinit(gpa);
        try commands.setCapacity(gpa, header.n_commands);
        commands.len = header.n_commands;
        break :mod .{
            .commands = commands.toOwnedSlice(),
            .parts = &.{},
            .patches = &.{},
            .extra = .empty,
            .strings = .empty,

            .title = header.title,
            .composer = header.composer,
            .arranger = header.arranger,
            .initial_tempo = .{ .bpm = header.initial_tempo_bpm },
        };
    };
    errdefer mod.deinit(gpa);

    mod.parts = try gpa.alloc(Part, header.n_parts);
    mod.patches = try gpa.alloc(Patch.Entry, header.n_patches);
    mod.extra = .{ .data = try gpa.alloc(Extra.Datum, header.n_extra) };
    mod.strings = .{ .bytes = try gpa.alloc(u8, header.strings_len) };

    const safety_buffer = if (data_has_safety_tag)
        try gpa.alloc(DataBytes, header.n_commands)
    else
        undefined;
    defer if (data_has_safety_tag) gpa.free(safety_buffer);

    var vecs = [_][]u8{
        @ptrCast(mod.commands.items(.tag)),
        if (data_has_safety_tag)
            @ptrCast(safety_buffer)
        else
            @ptrCast(mod.commands.items(.data)),
        @ptrCast(mod.commands.items(.span)),
        @ptrCast(mod.commands.items(.skipped)),
        @ptrCast(mod.parts),
        @ptrCast(mod.patches),
        @ptrCast(mod.extra.data),
        mod.strings.bytes,
    };
    try r.readVecAll(&vecs);

    if (data_has_safety_tag) {
        for (mod.commands.items(.data), mod.commands.items(.tag), safety_buffer) |*data, tag, data_bytes| {
            const as_hack: *HackDataLayout = @ptrCast(data);
            as_hack.* = .{
                .data = data_bytes,
                .safety_tag = @backingInt(Command.Tag.data_tags[@backingInt(tag)]),
            };
        }
    }

    return mod;
}

pub fn dumpJson(mod: *const Module, w: *Writer) Writer.Error!void {
    var out: std.json.Stringify = .{ .writer = w, .options = .{
        .whitespace = .indent_2,
    } };

    try out.beginObject();

    try out.objectField("commands");
    try out.beginArray();
    for (
        mod.commands.items(.tag),
        mod.commands.items(.data),
        mod.commands.items(.span),
        mod.commands.items(.skipped),
    ) |tag, data, span, skipped| {
        try out.beginObject();
        try out.objectField(@tagName(tag));
        switch (Command.Tag.data_tags[@backingInt(tag)]) {
            inline else => |data_tag| {
                if (data_tag == .none) {
                    try out.beginObject();
                    try out.endObject();
                } else {
                    try out.write(@field(data, @tagName(data_tag)));
                }
            },
        }
        if (tag != .end) {
            try out.objectField("span");
            try out.write(span);
        }
        if (skipped) {
            try out.objectField("skipped");
            try out.write(true);
        }
        try out.endObject();
    }
    try out.endArray();

    try out.objectField("parts");
    try out.write(mod.parts);

    try out.objectField("patches");
    try out.write(mod.patches);

    try out.objectField("extra");
    try out.write(mod.extra.data);

    try out.objectField("strings");
    try out.beginArray();
    {
        var i: usize = 0;
        while (std.mem.findScalarPos(u8, mod.strings.bytes, i, 0)) |end| : (i = end + 1) {
            try out.write(mod.strings.bytes[i..end]);
        }
        try out.write(mod.strings.bytes[i..]);
    }
    try out.endArray();

    try out.objectField("title");
    try out.write(@backingInt(mod.title));

    try out.objectField("composer");
    try out.write(@backingInt(mod.composer));

    try out.objectField("arranger");
    try out.write(@backingInt(mod.arranger));

    try out.objectField("initial_tempo");
    try out.write(mod.initial_tempo.bpm);

    try out.endObject();
}

pub const SourceIndex = enum(u32) {
    start,
    _,

    pub fn plusBytes(index: SourceIndex, bytes: u32) SourceIndex {
        return @fromBackingInt(@backingInt(index) + bytes);
    }

    pub const Span = struct {
        start: SourceIndex,
        end: SourceIndex,
    };
};

pub const SourceLocation = struct {
    line: u32,
    column: u32,

    pub const start: SourceLocation = .{
        .line = 1,
        .column = 1,
    };

    pub const Span = struct {
        start: SourceLocation,
        end: SourceLocation,
    };
};

pub const Ticks = enum(u32) {
    zero,
    _,

    pub const zenlen: Ticks = @fromBackingInt(96);

    pub fn plusOne(ticks: Ticks) Ticks {
        return @fromBackingInt(@backingInt(ticks) + 1);
    }

    pub fn minusOne(ticks: Ticks) Ticks {
        return @fromBackingInt(@backingInt(ticks) - 1);
    }

    pub fn plus(ticks: Ticks, amount: Ticks) Ticks {
        return @fromBackingInt(@backingInt(ticks) +| @backingInt(amount));
    }

    pub fn minus(ticks: Ticks, amount: Ticks) Ticks {
        return @fromBackingInt(@backingInt(ticks) -| @backingInt(amount));
    }

    pub fn fraction(ticks: Ticks, divisor: u32) error{NotDivisible}!Ticks {
        if (divisor == 0 or @backingInt(ticks) % divisor != 0) return error.NotDivisible;
        return @fromBackingInt(@divExact(@backingInt(ticks), divisor));
    }

    pub fn dot(ticks: Ticks) error{NotDivisible}!Ticks {
        if (@backingInt(ticks) % 2 != 0) return error.NotDivisible;
        return @fromBackingInt(@divExact(@backingInt(ticks), 2) *| 3);
    }
};

pub const Samples = enum(u32) {
    zero,
    _,

    pub fn plusOne(samples: Samples) Samples {
        return @fromBackingInt(@backingInt(samples) + 1);
    }

    pub fn minusOne(samples: Samples) Samples {
        return @fromBackingInt(@backingInt(samples) - 1);
    }
};

pub const Tempo = struct {
    bpm: f32,

    pub const default: Tempo = .fromBpm(120.0);

    pub fn fromBpm(bpm: f32) Tempo {
        return .{ .bpm = bpm };
    }

    pub fn samplesPerTick(tempo: Tempo) Samples {
        const zen_seconds = 60.0 / tempo.bpm * 4.0;
        return @fromBackingInt(@as(u32, @intFromFloat(@round(zen_seconds * zfm.sample_rate / @as(f32, @floatFromInt(@backingInt(Ticks.zenlen)))))));
    }
};

pub const Part = struct {
    name: u8,
    start: Command.Index,
    global_loop: Command.Index,
};

pub const Command = struct {
    tag: Tag,
    data: Data,
    span: SourceIndex.Span,
    skipped: bool,

    pub const Index = enum(u32) {
        _,

        pub fn next(index: Index) Index {
            return @fromBackingInt(@backingInt(index) + 1);
        }

        pub fn offset(index: Index, off: Offset) Index {
            return @fromBackingInt(@backingInt(index) +% @backingInt(off));
        }

        pub const Offset = enum(u32) {
            _,

            pub fn between(from: Index, to: Index) Offset {
                return @fromBackingInt(@backingInt(to) -% @backingInt(from));
            }
        };
    };
    pub const List = std.MultiArrayList(Command);

    pub const Tag = enum(u8) {
        end,
        rest,
        key_on,
        key_off,
        set_patch,
        set_volume,
        add_volume,
        set_tempo,
        add_tempo,
        set_pan,
        toggle_lfo,
        set_lfo_enabled,
        set_lfo_target,
        set_lfo_size,
        set_lfo_wave,
        set_lfo_trigger,
        set_lfo_adjust,
        loop,

        pub const data_tags = std.enums.directEnumArray(Tag, std.meta.FieldEnum(Data), 0, .{
            .end = .none,
            .rest = .ticks,
            .key_on = .freq,
            .key_off = .none,
            .set_patch = .extra,
            .set_volume = .amount,
            .add_volume = .amount,
            .set_tempo = .amount,
            .add_tempo = .amount,
            .set_pan = .amount,
            .toggle_lfo = .lfo,
            .set_lfo_enabled = .lfo_enabled,
            .set_lfo_target = .lfo_target,
            .set_lfo_size = .lfo_data,
            .set_lfo_wave = .lfo_data,
            .set_lfo_trigger = .lfo_trigger,
            .set_lfo_adjust = .lfo_adjust,
            .loop = .loop,
        });
    };

    pub const Data = union {
        none: void,
        ticks: Ticks,
        freq: f32,
        amount: f32,
        extra: Extra.Index,
        lfo: Lfo.Index,
        lfo_enabled: struct {
            index: Lfo.Index,
            enabled: bool,
        },
        lfo_target: struct {
            index: Lfo.Index,
            target: Lfo.Target,
        },
        lfo_trigger: struct {
            index: Lfo.Index,
            trigger: Lfo.Trigger,
        },
        lfo_adjust: struct {
            index: Lfo.Index,
            adjust: bool,
        },
        lfo_data: struct {
            index: Lfo.Index,
            data: Extra.Index,
        },
        loop: struct {
            branch: Command.Index.Offset,
            count: LoopCount,
        },

        comptime {
            if (!builtin.mode.runtimeSafety()) {
                assert(@sizeOf(Data) == 8);
            }
        }
    };
};

pub const Extra = struct {
    data: []Datum,

    pub const Datum = u32;
    pub const Index = enum(u32) {
        _,
        pub fn plus(index: Index, n: u32) Index {
            return @fromBackingInt(@backingInt(index) + n);
        }
    };

    pub const empty: Extra = .{ .data = &.{} };

    pub fn deinit(extra: *Extra, gpa: Allocator) void {
        gpa.free(extra.data);
        extra.* = undefined;
    }

    pub fn datum(extra: Extra, index: Index) Datum {
        return extra.data[@backingInt(index)];
    }

    pub fn decode(extra: Extra, T: type, index: Index) struct { T, Index } {
        if (std.meta.hasFn(T, "decode")) {
            return T.decode(extra, index);
        }
        return switch (T) {
            void => .{ {}, index },
            u32 => .{ extra.datum(index), index.plus(1) },
            u64 => .{
                extra.datum(index) | (@as(u64, extra.datum(index.plus(1))) << 32),
                index.plus(2),
            },
            f32 => .{ @bitCast(extra.datum(index)), index.plus(1) },
            else => switch (@typeInfo(T)) {
                .@"enum" => |@"enum"| {
                    const res, const next_index = extra.decode(@"enum".tag_type, index);
                    return .{ @fromBackingInt(res), next_index };
                },
                .@"struct" => |@"struct"| {
                    var res: T = undefined;
                    var current_index = index;
                    inline for (@"struct".field_names, @"struct".field_types) |field, field_type| {
                        @field(res, field), current_index = extra.decode(field_type, current_index);
                    }
                    return .{ res, current_index };
                },
                else => @compileError("cannot decode " ++ @typeName(T)),
            },
        };
    }

    pub const Wip = struct {
        data: std.ArrayList(Datum),

        pub const empty: Wip = .{ .data = .empty };

        pub fn deinit(wip: *Wip, gpa: Allocator) void {
            wip.data.deinit(gpa);
            wip.* = undefined;
        }

        pub fn currentIndex(wip: *const Wip) Extra.Index {
            return @fromBackingInt(@intCast(wip.data.items.len));
        }

        pub fn finish(wip: *Wip, gpa: Allocator) Allocator.Error!Extra {
            return .{ .data = try wip.data.toOwnedSlice(gpa) };
        }

        pub fn encode(wip: *Wip, gpa: Allocator, value: anytype) Allocator.Error!void {
            const T = @TypeOf(value);
            if (std.meta.hasFn(T, "encode")) {
                return value.encode(gpa, wip);
            }
            switch (T) {
                void => {},
                u32 => try wip.data.append(gpa, value),
                u64 => {
                    try wip.data.append(gpa, @truncate(value));
                    try wip.data.append(gpa, @truncate(value >> 32));
                },
                f32 => try wip.data.append(gpa, @bitCast(value)),
                else => switch (@typeInfo(T)) {
                    .@"enum" => try wip.encode(gpa, @backingInt(value)),
                    .@"struct" => |@"struct"| {
                        inline for (@"struct".field_names) |field| {
                            try wip.encode(gpa, @field(value, field));
                        }
                    },
                    else => @compileError("cannot encode " ++ @typeName(T)),
                },
            }
        }
    };
};

pub const Patch = struct {
    connections: Voice.Connections,
    slot_waves: [Voice.n_slots]Slot.Wave,
    slot_params: [Voice.n_slots]Slot.UserParams,
    slot_env_params: [Voice.n_slots]Envelope.UserParams,

    pub const Entry = struct {
        name: StringPool.Index,
        span: SourceIndex.Span,
        index: Extra.Index,
    };

    pub fn decode(extra: Extra, index: Extra.Index) struct { Patch, Extra.Index } {
        var res: Patch = undefined;
        var current_index = index;

        const packed_connections, current_index = extra.decode(Voice.Connections.Packed, current_index);
        res.connections = .fromPacked(packed_connections);
        for (&res.slot_waves) |*slot_wave| {
            slot_wave.*, current_index = extra.decode(Slot.Wave, current_index);
        }
        for (&res.slot_params) |*slot_params| {
            slot_params.*, current_index = extra.decode(Slot.UserParams, current_index);
        }
        for (&res.slot_env_params) |*slot_env_params| {
            slot_env_params.*, current_index = extra.decode(Envelope.UserParams, current_index);
        }

        return .{ res, current_index };
    }

    pub fn encode(patch: Patch, gpa: Allocator, wip: *Extra.Wip) Allocator.Error!void {
        try wip.encode(gpa, patch.connections.toPacked());
        for (patch.slot_waves) |slot_wave| {
            try wip.encode(gpa, slot_wave);
        }
        for (patch.slot_params) |slot_params| {
            try wip.encode(gpa, slot_params);
        }
        for (patch.slot_env_params) |slot_env_params| {
            try wip.encode(gpa, slot_env_params);
        }
    }
};

pub const Lfo = struct {
    target: Target,
    size: Size,
    wave: Wave,
    trigger: Trigger = .none,
    time_unit: TimeUnit = .seconds,
    adjust: bool = false,

    pub const Index = enum(u8) {
        user_0,
        user_1,
        user_2,
        user_3,
        porta,

        pub const User = u2;

        pub fn user(n: User) Index {
            return @fromBackingInt(@backingInt(Index.user_0) + n);
        }
    };

    pub const Target = enum(u32) {
        freq,
        pan,
        vol,
    };

    pub const Size = struct {
        scale: f32,
        offset: f32,

        pub const zero: Size = .{ .scale = 0.0, .offset = 0.0 };
    };

    pub const Wave = union(Tag) {
        con,
        sin: struct {
            freq: f32,
        },
        exp: struct {
            mul: f32,
        },

        pub const Tag = enum(u32) {
            con,
            sin,
            exp,
        };

        pub fn decode(extra: Extra, index: Extra.Index) struct { Wave, Extra.Index } {
            var res: Wave = undefined;
            var current_index = index;

            const wave_tag, current_index = extra.decode(Tag, current_index);
            switch (wave_tag) {
                inline else => |t| {
                    const Payload = @TypeOf(@field(@as(Wave, undefined), @tagName(t)));
                    const payload, current_index = extra.decode(Payload, current_index);
                    res = @unionInit(Wave, @tagName(t), payload);
                },
            }

            return .{ res, current_index };
        }

        pub fn encode(wave: Wave, gpa: Allocator, wip: *Extra.Wip) Allocator.Error!void {
            try wip.encode(gpa, @as(Tag, wave));
            switch (wave) {
                inline else => |v| try wip.encode(gpa, v),
            }
        }
    };

    pub const Trigger = enum(u32) {
        none,
        key_on,
    };

    pub const TimeUnit = enum(u32) {
        seconds,
        ticks,
    };
};

pub const max_loop_depth = 32;
pub const max_macro_depth = 32;

pub const LoopCount = enum(u8) {
    infinite,
    _,
};

const Module = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const zfm = @import("./zfm.zig");
const Synth = zfm.Synth;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const Driver = zfm.Driver;
const StringPool = @import("./StringPool.zig");
