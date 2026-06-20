commands: Command.List.Slice,
parts: []Part,
patches: std.array_hash_map.Auto(StringPool.Index, Extra.Index),
extra: Extra,
strings: StringPool.Slice,

title: StringPool.Index,
composer: StringPool.Index,
arranger: StringPool.Index,
initial_tempo: Tempo,

pub fn deinit(mod: *Module, gpa: Allocator) void {
    mod.commands.deinit(gpa);
    gpa.free(mod.parts);
    mod.patches.deinit(gpa);
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
        zero,
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
        loop,
    };

    pub const Data = union {
        none: void,
        ticks: Ticks,
        freq: f32,
        amount: f32,
        extra: Extra.Index,
        lfo: Lfo.Index,
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
                else => @compileError("cannot encode " ++ @typeName(T)),
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
    slot_params: [Voice.n_slots]Slot.Params,
    slot_env_params: [Voice.n_slots]Envelope.Params,

    pub fn decode(extra: Extra, index: Extra.Index) struct { Patch, Extra.Index } {
        var res: Patch = undefined;
        var current_index = index;

        const packed_connections, current_index = extra.decode(Voice.Connections.Packed, current_index);
        res.connections = .fromPacked(packed_connections);
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

    pub const Index = enum(u8) {
        porta,
        user_0,
        user_1,
        user_2,
        user_3,

        pub const User = u2;

        pub fn user(n: User) Index {
            return @enumFromInt(@intFromEnum(Index.user_0) + n);
        }
    };

    pub const Target = enum(u32) {
        freq,
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

    pub const TimeUnit = enum(u32) {
        seconds,
        ticks,
    };
};

pub const max_loop_depth = 32;

pub const LoopCount = enum(u8) {
    infinite,
    _,
};

const Module = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const zfm = @import("./zfm.zig");
const Synth = zfm.Synth;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const StringPool = @import("./StringPool.zig");
