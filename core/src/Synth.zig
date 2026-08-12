voices: []Voice,
slots: []Slot,
volume: f32,

pub const zero: Synth = .init(&.{}, &.{}, 0.0);

pub fn init(voices: []Voice, slots: []Slot, volume: f32) Synth {
    assert(slots.len == voices.len * Voice.n_slots);
    @memset(voices, .init(.init));
    @memset(slots, .init(.sine, .zero, .zero));
    return .{
        .voices = voices,
        .slots = slots,
        .volume = volume,
    };
}

pub fn voicePtr(synth: *Synth, voice: Voice.Index) *Voice {
    return &synth.voices[@backingInt(voice)];
}

pub fn voiceSlots(synth: *Synth, voice: Voice.Index) *[Voice.n_slots]Slot {
    return synth.slots[Voice.n_slots * @backingInt(voice) ..][0..Voice.n_slots];
}

pub fn slotPtr(synth: *Synth, slot: Slot.Index) *Slot {
    return &synth.slots[@backingInt(slot)];
}

pub fn voiceSlotPtr(synth: *Synth, voice: Voice.Index, slot: Voice.SlotIndex) *Slot {
    return &synth.slots[Voice.n_slots * @backingInt(voice) + slot];
}

pub fn keyOn(synth: *Synth, voice: Voice.Index) void {
    for (synth.voiceSlots(voice)) |*slot| slot.keyOn();
}

pub fn keyOff(synth: *Synth, voice: Voice.Index) void {
    for (synth.voiceSlots(voice)) |*slot| slot.keyOff();
}

pub fn sample(synth: *Synth) Frame {
    var total: Frame = @splat(0);
    for (synth.voices, 0..) |*voice, i| {
        const left, const right = voice.sample(synth.voiceSlots(@fromBackingInt(@intCast(i))));
        total[0] += std.math.clamp(synth.volume * left, -1.0, 1.0);
        total[1] += std.math.clamp(synth.volume * right, -1.0, 1.0);
    }
    return total;
}

pub const Voice = struct {
    deps: SlotDeps,
    connections: Connections,
    slot_order: [n_slots]SlotIndex,
    params: Params,

    pub const Index = enum(u32) { _ };

    pub const n_slots = 8;
    pub const SlotDeps = std.bit_set.Static(n_slots);
    pub const SlotIndex = std.math.IntFittingRange(0, n_slots - 1);
    pub const Connections = struct {
        deps: [n_slots]SlotDeps,

        pub const none: Connections = .{ .deps = @splat(.empty) };
        pub const Packed = u64;

        pub fn fromPairs(pairs: []const [2]SlotIndex) Connections {
            var conns: Connections = .none;
            for (pairs) |pair| conns.connect(pair[0], pair[1]);
            return conns;
        }

        pub fn fromPacked(p: Packed) Connections {
            return .{ .deps = @bitCast(p) };
        }

        pub fn toPacked(conns: Connections) Packed {
            return @bitCast(conns.deps);
        }

        pub fn connect(conns: *Connections, from: SlotIndex, to: SlotIndex) void {
            conns.deps[to].set(from);
        }

        pub const Computed = struct {
            deps: SlotDeps,
            slot_order: [n_slots]SlotIndex,
        };

        pub fn compute(conns: Connections) error{Cycle}!Computed {
            var deps: SlotDeps = .full;

            // We use Kahn's algorithm for topological sort to determine slot_order.
            var in_degrees: [n_slots]usize = undefined;
            for (conns.deps, &in_degrees) |slot_deps, *in_degree| {
                // deps is going to be all the slots which don't feed into another slot.
                deps = deps.differenceWith(slot_deps);
                in_degree.* = slot_deps.count();
            }

            // Queue of slots with in-degree 0:
            var queue: [n_slots]SlotIndex = undefined;
            var q_head: u8 = 0;
            var q_tail: u8 = 0;
            for (0..n_slots) |i| {
                if (in_degrees[i] == 0) {
                    queue[q_tail] = @intCast(i);
                    q_tail += 1;
                }
            }

            var slot_order: [n_slots]SlotIndex = undefined;
            var order_idx: u8 = 0;
            while (q_head < q_tail) {
                const slot = queue[q_head];
                q_head += 1;
                slot_order[order_idx] = slot;
                order_idx += 1;

                // Find all slots that `slot` feeds into:
                for (0..n_slots) |to| {
                    if (conns.deps[to].isSet(slot)) {
                        in_degrees[to] -= 1;
                        if (in_degrees[to] == 0) {
                            queue[q_tail] = @intCast(to);
                            q_tail += 1;
                        }
                    }
                }
            }

            if (order_idx != n_slots) {
                return error.Cycle;
            }

            return .{ .deps = deps, .slot_order = slot_order };
        }
    };

    pub const Params = struct {
        freq: f32,
        pan: f32,
        vol: f32,

        pub const init: Params = .{
            .freq = 0.0,
            .pan = 0.0,
            .vol = 1.0,
        };
    };

    pub fn init(params: Params) Voice {
        return .{
            .deps = .full,
            .connections = .none,
            .slot_order = std.simd.iota(SlotIndex, n_slots),
            .params = params,
        };
    }

    pub fn reconnect(voice: *Voice, conns: Connections) error{Cycle}!void {
        const computed = try conns.compute();

        voice.deps = computed.deps;
        voice.connections = conns;
        voice.slot_order = computed.slot_order;
    }

    pub fn sample(voice: *Voice, slots: *[n_slots]Slot) Frame {
        for (voice.slot_order) |i| {
            var phase: f32 = 0.0;
            var deps = voice.connections.deps[i].iterator(.{});
            while (deps.next()) |dep| phase += slots[dep].v;
            slots[i].update(voice.params.freq, phase);
        }
        var raw: f32 = 0.0;
        var tl: f32 = 0.0;
        var deps = voice.deps.iterator(.{});
        while (deps.next()) |dep| {
            raw += slots[dep].v;
            tl += slots[dep].params.tl;
        }
        raw = if (tl != 0.0) raw / tl else 0.0;
        const pan_left = @cos((voice.params.pan + 1.0) * std.math.tau / 8.0);
        const pan_right = @sin((voice.params.pan + 1.0) * std.math.tau / 8.0);
        return .{
            voice.params.vol * raw * pan_left,
            voice.params.vol * raw * pan_right,
        };
    }
};

pub const Slot = struct {
    state: State,
    v: f32,
    params: Params,
    env: Envelope,

    pub const Index = enum(u32) { _ };

    pub const Params = struct {
        tl: f32,
        ml: f32,
        fb: f32,
        ws: f32,

        pub const zero: Params = .{
            .tl = 0.0,
            .ml = 0.0,
            .fb = 0.0,
            .ws = 0.0,
        };
    };

    pub const Wave = enum(u32) {
        sine,
        square,
        triangle,
        saw,
        noise,

        pub fn usesWs(wave: Wave) bool {
            return switch (wave) {
                .square, .noise => true,
                .sine, .triangle, .saw => false,
            };
        }
    };

    pub const State = union(Wave) {
        sine: f32,
        square: f32,
        triangle: f32,
        saw: f32,
        noise: struct {
            rng: std.Random.Xoroshiro128,
            x1: f32,
            x2: f32,
            y1: f32,
            y2: f32,
        },

        pub fn init(wave: Wave) State {
            return switch (wave) {
                .sine => .{ .sine = 0.0 },
                .square => .{ .square = 0.0 },
                .triangle => .{ .triangle = 0.0 },
                .saw => .{ .saw = 0.0 },
                .noise => .{ .noise = .{
                    .rng = .init(0),
                    .x1 = 0.0,
                    .x2 = 0.0,
                    .y1 = 0.0,
                    .y2 = 0.0,
                } },
            };
        }

        pub fn sample(s: *State, freq: f32, phase: f32, ws: f32) f32 {
            switch (s.*) {
                .sine => |*t| {
                    const x = freq * t.* + phase;
                    const v = @sin(x * std.math.tau);
                    t.* = @mod(t.* + sample_time, 1.0 / freq);
                    return v;
                },
                .square => |*t| {
                    const x = freq * t.* + phase;
                    const duty_cycle = std.math.clamp(ws, 0.0001, 0.9999);
                    const v = 1.0 - 2.0 * @floor(x + 1.0 - duty_cycle) + 2.0 * @floor(x);
                    t.* = @mod(t.* + sample_time, 1.0 / freq);
                    return v;
                },
                .triangle => |*t| {
                    const x = freq * t.* + phase;
                    const v = 2.0 * @abs(2.0 * (x - @floor(x + 0.5))) - 1.0;
                    t.* = @mod(t.* + sample_time, 1.0 / freq);
                    return v;
                },
                .saw => |*t| {
                    const x = freq * t.* + phase;
                    const v = 2.0 * (x - @floor(x + 0.5));
                    t.* = @mod(t.* + sample_time, 1.0 / freq);
                    return v;
                },
                .noise => |*noise| {
                    const x0 = 2.0 * noise.rng.random().float(f32) - 1.0;
                    const freq_adj = @max(freq, 20.0);
                    // Bi-quad band pass algorithm
                    const q = @max(ws, 0.1);
                    const omega = std.math.tau * freq_adj / sample_rate;
                    const alpha = @sin(omega) / (2.0 * q);
                    const norm = 1.0 + alpha;
                    const b0 = alpha / norm;
                    const b2 = -alpha / norm;
                    const a1 = (-2.0 * @cos(omega)) / norm;
                    const a2 = (1.0 - alpha) / norm;
                    const y0 = b0 * x0 + b2 * noise.x2 - a1 * noise.y1 - a2 * noise.y2;
                    noise.x2 = noise.x1;
                    noise.x1 = x0;
                    noise.y2 = noise.y1;
                    noise.y1 = y0;
                    const correction = @sqrt(q * sample_rate / freq_adj);
                    return y0 * correction;
                },
            }
        }
    };

    pub fn init(wave: Wave, params: Params, env_params: Envelope.Params) Slot {
        return .{
            .state = .init(wave),
            .v = 0.0,
            .params = params,
            .env = .init(env_params),
        };
    }

    pub fn keyOn(slot: *Slot) void {
        slot.env.keyOn();
    }

    pub fn keyOff(slot: *Slot) void {
        slot.env.keyOff();
    }

    pub fn update(slot: *Slot, freq: f32, phase: f32) void {
        slot.env.update();
        const effective_freq = freq * slot.params.ml;
        const effective_phase = phase + slot.params.fb * slot.v;
        const effective_tl = slot.params.tl * slot.env.v;
        if (effective_freq > 0.0) {
            slot.v = effective_tl * slot.state.sample(effective_freq, effective_phase, slot.params.ws);
        } else {
            slot.v = 0.0;
        }
    }
};

pub const Envelope = struct {
    v: f32,
    params: Params,
    state: enum {
        idle,
        attack,
        decay,
        sustain,
        release,
    },

    /// Level below which an exponentially-decaying envelope is considered
    /// silent and snaps to zero (-80 dB).
    pub const silence: f32 = 1e-4;

    /// Raw envelope parameters in sample-rate-dependent units, as executed
    /// by `update`: `ar` is a per-sample level delta (linear attack), while
    /// `dr`, `sr` and `rr` are per-sample level multipliers (exponential
    /// decays). Convert from user-facing time units with `fromSeconds`.
    pub const Params = struct {
        ar: f32,
        dr: f32,
        sl: f32,
        sr: f32,
        rr: f32,

        pub const zero: Params = .{
            .ar = 0.0,
            .dr = 0.0,
            .sl = 0.0,
            .sr = 0.0,
            .rr = 0.0,
        };

        pub fn fromSeconds(tp: TimeParams) Params {
            return .{
                .ar = if (tp.ar > 0) @min(1 / (tp.ar * sample_rate), 1) else 0,
                .dr = mulTo(tp.sl, tp.dr),
                .sl = tp.sl,
                .sr = mulTo(silence, tp.sr),
                .rr = mulTo(silence, tp.rr),
            };
        }

        /// Per-sample multiplier for an exponential fall from level 1 to
        /// `target` over `time` seconds. Non-positive times hold the level
        /// indefinitely (multiplier 1).
        fn mulTo(target: f32, time: f32) f32 {
            if (time <= 0.0) return 1.0;
            return std.math.pow(f32, @max(target, silence), 1.0 / (time * sample_rate));
        }
    };

    /// User-facing envelope parameters. Rates are measured as the time in
    /// seconds the phase takes to reach the next envelope state:
    ///
    /// - `ar`: linear rise from 0 to 1.
    /// - `dr`: exponential fall from 1 to `sl`.
    /// - `sr`: exponential fall by a factor of `silence` (80 dB).
    /// - `rr`: exponential fall by a factor of `silence` (80 dB), from
    ///   whatever level the envelope is at on key-off.
    ///
    /// A rate of 0 means the phase never advances: the envelope holds at
    /// the phase's starting level until key-off. `sl` is a level in [0, 1].
    pub const TimeParams = struct {
        ar: f32,
        dr: f32,
        sl: f32,
        sr: f32,
        rr: f32,

        pub const zero: TimeParams = .{
            .ar = 0.0,
            .dr = 0.0,
            .sl = 0.0,
            .sr = 0.0,
            .rr = 0.0,
        };
    };

    pub fn init(params: Params) Envelope {
        return .{
            .v = 0.0,
            .params = params,
            .state = .idle,
        };
    }

    pub fn keyOn(env: *Envelope) void {
        if (env.state == .idle or env.state == .release) {
            env.state = .attack;
            env.v = 0.0;
        }
    }

    pub fn keyOff(env: *Envelope) void {
        if (env.state != .idle) {
            env.state = .release;
        }
    }

    pub fn update(env: *Envelope) void {
        switch (env.state) {
            .idle => {},
            .attack => {
                env.v += env.params.ar;
                if (env.v >= 1.0) {
                    env.v = 1.0;
                    env.state = .decay;
                }
            },
            .decay => {
                env.v *= env.params.dr;
                if (env.v <= env.params.sl or env.v < silence) {
                    env.v = env.params.sl;
                    env.state = .sustain;
                }
            },
            .sustain => {
                env.v *= env.params.sr;
                if (env.v < silence) env.v = 0.0;
            },
            .release => {
                env.v *= env.params.rr;
                if (env.v < silence) {
                    env.v = 0.0;
                    env.state = .idle;
                }
            },
        }
    }
};

const Synth = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const zfm = @import("./zfm.zig");
const Frame = zfm.Frame;
const sample_rate = zfm.sample_rate;
const sample_time = zfm.sample_time;
