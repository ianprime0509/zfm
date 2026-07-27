commands: Command.List.Slice,
parts: []Part,
patches: std.array_hash_map.Auto(StringPool.Index, Extra.Index),
macros: std.array_hash_map.Auto(StringPool.Index, SourceIndex),
extra: Extra,
strings: StringPool.Slice,

title: StringPool.Index,
composer: StringPool.Index,
arranger: StringPool.Index,
initial_tempo: Tempo,

pub const version: u8 = 0;

pub const empty: Module = .{
    .commands = .empty,
    .parts = &.{},
    .patches = .empty,
    .macros = .empty,
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
    mod.patches.deinit(gpa);
    mod.macros.deinit(gpa);
    mod.extra.deinit(gpa);
    mod.strings.deinit(gpa);
    mod.* = undefined;
}

pub fn tag(mod: *const Module, command: Command.Index) Command.Tag {
    return mod.commands.items(.tag)[@intFromEnum(command)];
}

pub fn data(mod: *const Module, command: Command.Index) Command.Data {
    return mod.commands.items(.data)[@intFromEnum(command)];
}

pub fn write(mod: *const Module, w: *Writer) Writer.Error!void {
    try w.writeByte(version);

    try w.writeInt(u32, @intFromEnum(mod.title), .little);
    try w.writeInt(u32, @intFromEnum(mod.composer), .little);
    try w.writeInt(u32, @intFromEnum(mod.arranger), .little);
    try w.writeInt(u32, @bitCast(mod.initial_tempo.bpm), .little);

    try w.writeByte(@intCast(mod.parts.len));
    for (mod.parts) |part| {
        try w.writeInt(u32, @intFromEnum(part.start), .little);
        try w.writeInt(u32, @intFromEnum(part.global_loop), .little);
    }

    try w.writeInt(u32, @intCast(mod.patches.count()), .little);
    for (mod.patches.keys(), mod.patches.values()) |key, value| {
        try w.writeInt(u32, @intFromEnum(key), .little);
        try w.writeInt(u32, @intFromEnum(value), .little);
    }

    try w.writeInt(u32, @intCast(mod.macros.count()), .little);
    for (mod.macros.keys(), mod.macros.values()) |key, value| {
        try w.writeInt(u32, @intFromEnum(key), .little);
        try w.writeInt(u32, @intFromEnum(value), .little);
    }

    try w.writeInt(u32, @intCast(mod.extra.data.len), .little);
    for (mod.extra.data) |datum| {
        try w.writeInt(Extra.Datum, datum, .little);
    }

    try w.writeInt(u32, @intCast(mod.strings.bytes.len), .little);
    try w.writeAll(mod.strings.bytes);

    // Commands are written last, because decoding the commands requires knowing
    // the data associated to each tag. If new tags are added later which readers
    // don't understand, at least they can still read the other metadata.
    for (mod.commands.items(.tag), mod.commands.items(.data)) |t, d| {
        try w.writeByte(@intFromEnum(t));
        switch (t) {
            .end,
            .key_off,
            => {
                // No data.
            },
            .rest,
            => {
                try w.writeInt(u32, @intFromEnum(d.ticks), .little);
            },
            .key_on,
            => {
                try w.writeInt(u32, @bitCast(d.freq), .little);
            },
            .set_patch,
            => {
                try w.writeInt(u32, @intFromEnum(d.extra), .little);
            },
            .set_volume,
            .add_volume,
            => {
                try w.writeInt(u32, @bitCast(d.amount), .little);
            },
            .toggle_lfo,
            => {
                try w.writeInt(u32, @intFromEnum(d.lfo), .little);
            },
            .set_lfo_target,
            => {
                try w.writeInt(u32, @intFromEnum(d.lfo_target.index), .little);
                try w.writeInt(u32, @intFromEnum(d.lfo_target.target), .little);
            },
            .set_lfo_trigger,
            => {
                try w.writeInt(u32, @intFromEnum(d.lfo_trigger.index), .little);
                try w.writeInt(u32, @intFromEnum(d.lfo_trigger.trigger), .little);
            },
            .set_lfo_adjust,
            => {
                try w.writeInt(u32, @intFromEnum(d.lfo_adjust.index), .little);
                try w.writeInt(u8, @intFromBool(d.lfo_adjust.adjust), .little);
            },
            .set_lfo_size,
            .set_lfo_wave,
            => {
                try w.writeInt(u32, @intFromEnum(d.lfo_data.index), .little);
                try w.writeInt(u32, @intFromEnum(d.lfo_data.data), .little);
            },
            .loop,
            => {
                try w.writeInt(u32, @intFromEnum(d.loop.branch), .little);
                try w.writeInt(u32, @intFromEnum(d.loop.count), .little);
            },
        }
    }
    try w.writeByte(0xFF);
}

pub const ReadUncheckedError = Allocator.Error || Reader.Error || error{UnsupportedVersion};

pub fn readUnchecked(gpa: Allocator, r: *Reader) ReadUncheckedError!Module {
    if (try r.takeByte() != version) return error.UnsupportedVersion;

    const title: StringPool.Index = @enumFromInt(try r.takeInt(u32, .little));
    const composer: StringPool.Index = @enumFromInt(try r.takeInt(u32, .little));
    const arranger: StringPool.Index = @enumFromInt(try r.takeInt(u32, .little));
    const initial_tempo: Tempo = .{ .bpm = @bitCast(try r.takeInt(u32, .little)) };

    const n_parts = try r.takeByte();
    const parts = try gpa.alloc(Part, n_parts);
    errdefer gpa.free(parts);
    for (parts) |*part| {
        part.* = .{
            .start = @enumFromInt(try r.takeInt(u32, .little)),
            .global_loop = @enumFromInt(try r.takeInt(u32, .little)),
        };
    }

    const n_patches = try r.takeInt(u32, .little);
    var patches: std.array_hash_map.Auto(StringPool.Index, Extra.Index) = .empty;
    errdefer patches.deinit(gpa);
    try patches.ensureTotalCapacity(gpa, n_patches);
    for (0..n_patches) |_| {
        patches.putAssumeCapacity(
            @enumFromInt(try r.takeInt(u32, .little)),
            @enumFromInt(try r.takeInt(u32, .little)),
        );
    }

    const n_macros = try r.takeInt(u32, .little);
    var macros: std.array_hash_map.Auto(StringPool.Index, SourceIndex) = .empty;
    errdefer macros.deinit(gpa);
    try macros.ensureTotalCapacity(gpa, n_macros);
    for (0..n_macros) |_| {
        macros.putAssumeCapacity(
            @enumFromInt(try r.takeInt(u32, .little)),
            @enumFromInt(try r.takeInt(u32, .little)),
        );
    }

    const n_extra_data = try r.takeInt(u32, .little);
    const extra_data = try gpa.alloc(Extra.Datum, n_extra_data);
    errdefer gpa.free(extra_data);
    for (extra_data) |*datum| {
        datum.* = try r.takeInt(Extra.Datum, .little);
    }

    const strings_bytes_len = try r.takeInt(u32, .little);
    const strings_bytes = try gpa.alloc(u8, strings_bytes_len);
    errdefer gpa.free(strings_bytes);
    try r.readSliceAll(strings_bytes);

    var commands: Command.List = .empty;
    errdefer commands.deinit(gpa);
    while (true) {
        const t_raw = try r.takeByte();
        if (t_raw == 0xFF) break;
        const t = std.enums.fromInt(Command.Tag, t_raw) orelse return error.UnsupportedVersion;
        const d: Command.Data = switch (t) {
            .end,
            .key_off,
            => .{
                .none = {},
            },
            .rest,
            => .{
                .ticks = @enumFromInt(try r.takeInt(u32, .little)),
            },
            .key_on,
            => .{
                .freq = @bitCast(try r.takeInt(u32, .little)),
            },
            .set_patch,
            => .{
                .extra = @enumFromInt(try r.takeInt(u32, .little)),
            },
            .set_volume,
            .add_volume,
            => .{
                .amount = @bitCast(try r.takeInt(u32, .little)),
            },
            .toggle_lfo,
            => .{
                .lfo = @enumFromInt(try r.takeInt(u32, .little)),
            },
            .set_lfo_target,
            => .{
                .lfo_target = .{
                    .index = @enumFromInt(try r.takeInt(u32, .little)),
                    .target = @enumFromInt(try r.takeInt(u32, .little)),
                },
            },
            .set_lfo_trigger,
            => .{
                .lfo_trigger = .{
                    .index = @enumFromInt(try r.takeInt(u32, .little)),
                    .trigger = @enumFromInt(try r.takeInt(u32, .little)),
                },
            },
            .set_lfo_adjust,
            => .{
                .lfo_adjust = .{
                    .index = @enumFromInt(try r.takeInt(u32, .little)),
                    .adjust = try r.takeByte() != 0,
                },
            },
            .set_lfo_size,
            .set_lfo_wave,
            => .{
                .lfo_data = .{
                    .index = @enumFromInt(try r.takeInt(u32, .little)),
                    .data = @enumFromInt(try r.takeInt(u32, .little)),
                },
            },
            .loop,
            => .{
                .loop = .{
                    .branch = @enumFromInt(try r.takeInt(u32, .little)),
                    .count = @enumFromInt(try r.takeInt(u32, .little)),
                },
            },
        };
        try commands.append(gpa, .{ .tag = t, .data = d });
    }

    return .{
        .commands = commands.toOwnedSlice(),
        .parts = parts,
        .patches = patches,
        .macros = macros,
        .extra = .{ .data = extra_data },
        .strings = .{ .bytes = strings_bytes },
        .title = title,
        .composer = composer,
        .arranger = arranger,
        .initial_tempo = initial_tempo,
    };
}

pub const SourceIndex = enum(u32) {
    start,
    _,

    pub fn next(index: SourceIndex) SourceIndex {
        return @enumFromInt(@intFromEnum(index) + 1);
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

    pub const zenlen: Ticks = @enumFromInt(96);

    pub fn minusOne(ticks: Ticks) Ticks {
        return @enumFromInt(@intFromEnum(ticks) - 1);
    }

    pub fn plus(ticks: Ticks, more: Ticks) Ticks {
        return @enumFromInt(@intFromEnum(ticks) + @intFromEnum(more));
    }

    pub fn fraction(ticks: Ticks, divisor: u32) error{NotDivisible}!Ticks {
        if (divisor == 0 or @intFromEnum(ticks) % divisor != 0) return error.NotDivisible;
        return @enumFromInt(@divExact(@intFromEnum(ticks), divisor));
    }

    pub fn dot(ticks: Ticks) error{NotDivisible}!Ticks {
        if (@intFromEnum(ticks) % 2 != 0) return error.NotDivisible;
        return @enumFromInt(@divExact(@intFromEnum(ticks), 2) * 3);
    }
};

pub const Samples = enum(u32) {
    zero,
    _,

    pub fn plusOne(samples: Samples) Samples {
        return @enumFromInt(@intFromEnum(samples) + 1);
    }

    pub fn minusOne(samples: Samples) Samples {
        return @enumFromInt(@intFromEnum(samples) - 1);
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
        return @enumFromInt(@as(u32, @intFromFloat(@round(zen_seconds * zfm.sample_rate / @as(f32, @floatFromInt(@intFromEnum(Ticks.zenlen)))))));
    }
};

pub const Part = struct {
    start: Command.Index,
    global_loop: Command.Index,
};

pub const Command = struct {
    tag: Tag,
    data: Data,

    pub const Index = enum(u32) {
        _,

        pub fn next(index: Index) Index {
            return @enumFromInt(@intFromEnum(index) + 1);
        }

        pub fn offset(index: Index, off: Offset) Index {
            return @enumFromInt(@intFromEnum(index) +% @intFromEnum(off));
        }

        pub const Offset = enum(u32) {
            _,

            pub fn between(from: Index, to: Index) Offset {
                return @enumFromInt(@intFromEnum(to) -% @intFromEnum(from));
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
        toggle_lfo,
        set_lfo_target,
        set_lfo_size,
        set_lfo_wave,
        set_lfo_trigger,
        set_lfo_adjust,
        loop,
    };

    pub const Data = union {
        none: void,
        ticks: Ticks,
        freq: f32,
        amount: f32,
        extra: Extra.Index,
        lfo: Lfo.Index,
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
    };
};

pub const Extra = struct {
    data: []Datum,

    pub const Datum = u32;
    pub const Index = enum(u32) {
        _,
        pub fn plus(index: Index, n: u32) Index {
            return @enumFromInt(@intFromEnum(index) + n);
        }
    };

    pub const empty: Extra = .{ .data = &.{} };

    pub fn deinit(extra: *Extra, gpa: Allocator) void {
        gpa.free(extra.data);
        extra.* = undefined;
    }

    pub fn datum(extra: Extra, index: Index) Datum {
        return extra.data[@intFromEnum(index)];
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
                    return .{ @enumFromInt(res), next_index };
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
            return @enumFromInt(wip.data.items.len);
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
                    .@"enum" => try wip.encode(gpa, @intFromEnum(value)),
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
    slot_params: [Voice.n_slots]Slot.Params,
    slot_env_params: [Voice.n_slots]Envelope.Params,

    pub fn decode(extra: Extra, index: Extra.Index) struct { Patch, Extra.Index } {
        var res: Patch = undefined;
        var current_index = index;

        const packed_connections, current_index = extra.decode(Voice.Connections.Packed, current_index);
        res.connections = .fromPacked(packed_connections);
        for (&res.slot_waves) |*slot_wave| {
            slot_wave.*, current_index = extra.decode(Slot.Wave, current_index);
        }
        for (&res.slot_params) |*slot_params| {
            slot_params.*, current_index = extra.decode(Slot.Params, current_index);
        }
        for (&res.slot_env_params) |*slot_env_params| {
            slot_env_params.*, current_index = extra.decode(Envelope.Params, current_index);
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
            return @enumFromInt(@intFromEnum(Index.user_0) + n);
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
        constant,
        sine: struct {
            freq: f32,
        },
        exp: struct {
            mul: f32,
        },

        pub const Tag = enum(u32) {
            constant,
            sine,
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

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const zfm = @import("./zfm.zig");
const Synth = zfm.Synth;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const StringPool = @import("./StringPool.zig");
