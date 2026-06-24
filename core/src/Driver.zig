synth: *Synth,
mod: *const Module,
parts: []Part,
tick_delay: Samples,
lfo_delay: Samples,
tempo: Tempo,

const lfo_delay_reset: Samples = @enumFromInt(48);

pub fn init(synth: *Synth, mod: *const Module, parts: []Part) Driver {
    assert(parts.len == mod.parts.len);
    for (parts, mod.parts) |*part, mod_part| part.* = .init(mod_part);
    return .{
        .synth = synth,
        .mod = mod,
        .parts = parts,
        .tick_delay = .zero,
        .lfo_delay = .zero,
        .tempo = mod.initial_tempo,
    };
}

pub fn partPtr(driver: *Driver, voice: Voice.Index) *Part {
    return &driver.parts[@intFromEnum(voice)];
}

pub fn sample(driver: *Driver) Frame {
    if (driver.lfo_delay == .zero) {
        driver.tickLfos();
        driver.lfo_delay = lfo_delay_reset;
    }
    driver.lfo_delay = driver.lfo_delay.minusOne();
    if (driver.tick_delay == .zero) {
        driver.tick();
        driver.tick_delay = driver.tempo.samplesPerTick();
    }
    driver.tick_delay = driver.tick_delay.minusOne();
    return driver.synth.sample();
}

fn tick(driver: *Driver) void {
    for (driver.parts, 0..) |*part, i| {
        const voice: Voice.Index = @enumFromInt(i);
        driver.executePending(part, voice);
    }
}

fn tickLfos(driver: *Driver) void {
    for (driver.parts, 0..) |*part, i| {
        const voice: Voice.Index = @enumFromInt(i);
        var sp = part.synth_params;
        for (&part.lfos.values) |*lfo| lfo.process(&sp, lfo_delay_reset, driver.tempo);
        sp.applyTo(driver.synth, voice);
    }
}

fn executePending(driver: *Driver, part: *Part, voice: Voice.Index) void {
    while (part.delay == .zero) {
        if (part.ended) return;
        const next_command = driver.execute(part, voice, part.command);
        part.command = next_command;
    }
    part.delay = part.delay.minusOne();
}

fn execute(
    driver: *Driver,
    part: *Part,
    voice: Voice.Index,
    command: Command.Index,
) Command.Index {
    switch (driver.mod.tag(command)) {
        .end => {
            if (part.global_loop == command) {
                // No global loop.
                part.ended = true;
                return command;
            } else {
                part.cycle +|= 1;
                return part.global_loop;
            }
        },
        .rest => {
            part.delay = driver.mod.data(command).ticks;
            return command.next();
        },
        .key_on => {
            part.keyOn(driver.mod.data(command).freq);
            driver.synth.keyOn(voice);
            return command.next();
        },
        .key_off => {
            driver.synth.keyOff(voice);
            return command.next();
        },
        .set_patch => {
            const patch, _ = driver.mod.extra.decode(Patch, driver.mod.data(command).extra);
            driver.synth.voicePtr(voice).reconnect(patch.connections) catch unreachable;
            for (patch.slot_waves, 0..) |wave, slot| {
                driver.synth.voiceSlotPtr(voice, @intCast(slot)).state = .init(wave);
            }
            part.synth_params.slot = patch.slot_params;
            part.synth_params.slot_env = patch.slot_env_params;
            return command.next();
        },
        .set_volume => {
            part.synth_params.voice.vol = driver.mod.data(command).amount;
            return command.next();
        },
        .add_volume => {
            part.synth_params.voice.vol += driver.mod.data(command).amount;
            return command.next();
        },
        .toggle_lfo => {
            const index = driver.mod.data(command).lfo;
            const lfo = part.lfoPtr(index);
            lfo.enabled = !lfo.enabled;
            lfo.t = 0.0;
            return command.next();
        },
        .set_lfo_target => {
            const lfo_target = driver.mod.data(command).lfo_target;
            part.lfoPtr(lfo_target.index).params.target = lfo_target.target;
            return command.next();
        },
        .set_lfo_size => {
            const lfo_data = driver.mod.data(command).lfo_data;
            const lfo = part.lfoPtr(lfo_data.index);
            lfo.params.size, _ = driver.mod.extra.decode(Lfo.Size, lfo_data.data);
            return command.next();
        },
        .set_lfo_wave => {
            const lfo_data = driver.mod.data(command).lfo_data;
            const lfo = part.lfoPtr(lfo_data.index);
            lfo.params.wave, _ = driver.mod.extra.decode(Lfo.Wave, lfo_data.data);
            return command.next();
        },
        .set_lfo_trigger => {
            const lfo_trigger = driver.mod.data(command).lfo_trigger;
            part.lfoPtr(lfo_trigger.index).params.trigger = lfo_trigger.trigger;
            return command.next();
        },
        .set_lfo_adjust => {
            const lfo_adjust = driver.mod.data(command).lfo_adjust;
            part.lfoPtr(lfo_adjust.index).params.adjust = lfo_adjust.adjust;
            return command.next();
        },
        .loop => {
            const loop = driver.mod.data(command).loop;
            if (part.loops.shouldLoop(command, loop.count)) {
                return command.offset(loop.branch);
            } else {
                return command.next();
            }
        },
    }
}

pub fn keyOn(driver: *Driver, voice: Voice.Index, freq: f32) void {
    driver.partPtr(voice).keyOn(freq);
    driver.synth.keyOn(voice);
}

pub fn keyOff(driver: *Driver, voice: Voice.Index) void {
    driver.synth.keyOff(voice);
}

pub fn reconnect(driver: *Driver, voice: Voice.Index, connections: Voice.Connections) error{Cycle}!void {
    try driver.synth.voicePtr(voice).reconnect(connections);
}

pub fn setSlotWave(driver: *Driver, voice: Voice.Index, slot: Voice.SlotIndex, wave: Slot.Wave) void {
    driver.synth.voiceSlotPtr(voice, slot).state = .init(wave);
}

pub fn setSlotParams(driver: *Driver, voice: Voice.Index, slot: Voice.SlotIndex, params: Slot.Params) void {
    driver.partPtr(voice).synth_params.slot[slot] = params;
}

pub fn setSlotEnvParams(driver: *Driver, voice: Voice.Index, slot: Voice.SlotIndex, params: Envelope.Params) void {
    driver.partPtr(voice).synth_params.slot_env[slot] = params;
}

pub fn enableLfo(driver: *Driver, voice: Voice.Index, index: Lfo.Index) void {
    const lfo = driver.partPtr(voice).lfoPtr(index);
    lfo.enabled = true;
    lfo.t = 0.0;
}

pub fn disableLfo(driver: *Driver, voice: Voice.Index, index: Lfo.Index) void {
    const lfo = driver.partPtr(voice).lfoPtr(index);
    lfo.enabled = false;
    lfo.t = 0.0;
}

pub fn setLfoParams(driver: *Driver, voice: Voice.Index, index: Lfo.Index, params: Lfo) void {
    driver.partPtr(voice).lfoPtr(index).params = params;
}

pub const Part = struct {
    command: Command.Index,
    delay: Ticks,
    cycle: u8,
    global_loop: Command.Index,
    loops: Loop.Stack,
    synth_params: SynthParams,
    lfos: std.EnumArray(Lfo.Index, LfoState),
    ended: bool,

    fn init(mod_part: Module.Part) Part {
        var part: Part = .{
            .command = mod_part.start,
            .delay = .zero,
            .cycle = 0,
            .global_loop = mod_part.global_loop,
            .loops = .empty,
            .synth_params = .init,
            .lfos = .initFill(.init),
            .ended = false,
        };
        part.lfos.getPtr(.porta).params.time_unit = .ticks;
        return part;
    }

    fn lfoPtr(part: *Part, index: Lfo.Index) *LfoState {
        return part.lfos.getPtr(index);
    }

    fn keyOn(part: *Part, freq: f32) void {
        part.synth_params.voice.freq = freq;
        for (&part.lfos.values) |*lfo| {
            if (lfo.params.trigger == .key_on) lfo.t = 0.0;
        }
    }

    pub const Loop = struct {
        command: Command.Index,
        iteration: u8,

        pub const Stack = struct {
            loops: [max_loop_depth]Loop,
            len: std.math.IntFittingRange(0, max_loop_depth),

            const empty: Stack = .{ .loops = undefined, .len = 0 };

            fn shouldLoop(s: *Stack, command: Command.Index, count: LoopCount) bool {
                if (s.len == 0 or s.loops[s.len - 1].command != command) {
                    s.loops[s.len] = .{ .command = command, .iteration = 0 };
                    s.len += 1;
                }
                const loop = &s.loops[s.len - 1];
                loop.iteration +%= 1;
                const res = count == .infinite or loop.iteration < @intFromEnum(count);
                if (!res) s.len -= 1;
                return res;
            }
        };
    };

    pub const LfoState = struct {
        enabled: bool,
        params: Lfo,
        t: f32,

        const init: LfoState = .{
            .enabled = false,
            .params = .{
                .target = .freq,
                .size = .zero,
                .wave = .constant,
            },
            .t = 0.0,
        };

        fn process(lfo: *LfoState, sp: *SynthParams, elapsed_samples: Samples, tempo: Tempo) void {
            if (!lfo.enabled) return;
            const v = lfo.sample(elapsed_samples, tempo, sp.voice.freq);
            switch (lfo.params.target) {
                .freq => sp.voice.freq = std.math.clamp(sp.voice.freq + v, 0.0, 22_000.0),
                .pan => sp.voice.pan = std.math.clamp(sp.voice.pan + v, -1.0, 1.0),
                .vol => sp.voice.vol = std.math.clamp(sp.voice.vol + v, 0.0, 1.0),
            }
        }

        fn sample(lfo: *LfoState, elapsed_samples: Samples, tempo: Tempo, note_freq: f32) f32 {
            const elapsed_time = switch (lfo.params.time_unit) {
                .seconds => @as(f32, @floatFromInt(@intFromEnum(elapsed_samples))) * zfm.sample_time,
                .ticks => @as(f32, @floatFromInt(@intFromEnum(elapsed_samples))) / @as(f32, @floatFromInt(@intFromEnum(tempo.samplesPerTick()))),
            };
            const base = base: switch (lfo.params.wave) {
                .constant => 1.0,
                .sine => |params| {
                    const v = @sin(params.freq * lfo.t * std.math.tau);
                    lfo.t = @mod(lfo.t + elapsed_time, 1 / params.freq);
                    break :base v;
                },
                .exp => |params| {
                    const v = @exp2(lfo.adjusted(params.mul, note_freq) * lfo.t);
                    lfo.t += elapsed_time;
                    break :base v;
                },
            };
            return lfo.adjusted(lfo.params.size.scale * base + lfo.params.size.offset, note_freq);
        }

        fn adjusted(lfo: *const LfoState, val: f32, note_freq: f32) f32 {
            return if (lfo.params.adjust) val * note_freq / 440.0 else val;
        }
    };

    pub const SynthParams = struct {
        voice: Voice.Params,
        slot: [Voice.n_slots]Slot.Params,
        slot_env: [Voice.n_slots]Envelope.Params,

        pub const init: SynthParams = .{
            .voice = .init,
            .slot = @splat(.zero),
            .slot_env = @splat(.zero),
        };

        fn applyTo(sp: SynthParams, synth: *Synth, voice: Voice.Index) void {
            synth.voicePtr(voice).params = sp.voice;
            for (synth.voiceSlots(voice), sp.slot, sp.slot_env) |*slot, slot_params, env_params| {
                slot.params = slot_params;
                slot.env.params = env_params;
            }
        }
    };
};

const Driver = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const zfm = @import("./zfm.zig");
const Frame = zfm.Frame;
const Synth = zfm.Synth;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const Module = zfm.Module;
const Command = Module.Command;
const Patch = Module.Patch;
const Lfo = Module.Lfo;
const Ticks = Module.Ticks;
const Samples = Module.Samples;
const Tempo = Module.Tempo;
const LoopCount = Module.LoopCount;
const max_loop_depth = Module.max_loop_depth;
