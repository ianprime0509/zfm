synth: *Synth,
mod: *const Module,
parts: []Part,
tick_delay: Samples,
lfo_delay: Samples,
tempo: Tempo,
elapsed_ticks: Ticks,
hooks: Hooks = .none,

const lfo_delay_reset: Samples = @fromBackingInt(48);

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
        .elapsed_ticks = .zero,
    };
}

pub fn partPtr(driver: *Driver, voice: Voice.Index) *Part {
    return &driver.parts[@backingInt(voice)];
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
        const voice: Voice.Index = @fromBackingInt(@intCast(i));
        driver.executePending(part, voice);
    }
    driver.elapsed_ticks = driver.elapsed_ticks.plusOne();
}

fn tickLfos(driver: *Driver) void {
    for (driver.parts, 0..) |*part, i| {
        const voice: Voice.Index = @fromBackingInt(@intCast(i));
        var sp = part.synth_params;
        for (&part.lfos.values) |*lfo| lfo.process(&sp, lfo_delay_reset, driver.tempo);
        sp.applyTo(driver.synth, voice);
    }
}

fn executePending(driver: *Driver, part: *Part, voice: Voice.Index) void {
    while (part.delay == .zero) {
        if (part.ended) return;
        part.executing_command = part.next_command;
        part.next_command = driver.execute(part, voice, part.executing_command);
    }
    part.delay = part.delay.minusOne();
}

fn execute(
    driver: *Driver,
    part: *Part,
    voice: Voice.Index,
    command: Command.Index,
) Command.Index {
    if (driver.mod.commandSkipped(command)) {
        // The only commands which can be skipped are key_on, key_off, and rest,
        // so it is safe to just go to the immediately next command.
        return command.next();
    }

    driver.hooks.onExecuteCommand(driver, part, voice, command);

    switch (driver.mod.commandTag(command)) {
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
            part.delay = driver.mod.commandData(command).ticks;
            return command.next();
        },
        .key_on => {
            driver.keyOn(voice, driver.mod.commandData(command).freq);
            driver.synth.keyOn(voice);
            return command.next();
        },
        .key_off => {
            driver.keyOff(voice);
            return command.next();
        },
        .set_patch => {
            const patch, _ = driver.mod.extra.decode(Patch, driver.mod.commandData(command).extra);
            driver.setPatch(voice, patch);
            return command.next();
        },
        .set_volume => {
            part.synth_params.voice.vol = driver.mod.commandData(command).amount;
            return command.next();
        },
        .add_volume => {
            part.synth_params.voice.vol += driver.mod.commandData(command).amount;
            return command.next();
        },
        .set_tempo => {
            driver.tempo.bpm = driver.mod.commandData(command).amount;
            return command.next();
        },
        .add_tempo => {
            driver.tempo.bpm += driver.mod.commandData(command).amount;
            return command.next();
        },
        .set_pan => {
            part.synth_params.voice.pan = driver.mod.commandData(command).amount;
            return command.next();
        },
        .toggle_lfo => {
            const index = driver.mod.commandData(command).lfo;
            driver.setLfoEnabled(voice, index, !part.lfoPtr(index).enabled);
            return command.next();
        },
        .set_lfo_enabled => {
            const lfo_enabled = driver.mod.commandData(command).lfo_enabled;
            driver.setLfoEnabled(voice, lfo_enabled.index, lfo_enabled.enabled);
            return command.next();
        },
        .set_lfo_target => {
            const lfo_target = driver.mod.commandData(command).lfo_target;
            part.lfoPtr(lfo_target.index).params.target = lfo_target.target;
            return command.next();
        },
        .set_lfo_size => {
            const lfo_data = driver.mod.commandData(command).lfo_data;
            const lfo = part.lfoPtr(lfo_data.index);
            lfo.params.size, _ = driver.mod.extra.decode(Lfo.Size, lfo_data.data);
            return command.next();
        },
        .set_lfo_wave => {
            const lfo_data = driver.mod.commandData(command).lfo_data;
            const lfo = part.lfoPtr(lfo_data.index);
            lfo.params.wave, _ = driver.mod.extra.decode(Lfo.Wave, lfo_data.data);
            return command.next();
        },
        .set_lfo_trigger => {
            const lfo_trigger = driver.mod.commandData(command).lfo_trigger;
            part.lfoPtr(lfo_trigger.index).params.trigger = lfo_trigger.trigger;
            return command.next();
        },
        .set_lfo_adjust => {
            const lfo_adjust = driver.mod.commandData(command).lfo_adjust;
            part.lfoPtr(lfo_adjust.index).params.adjust = lfo_adjust.adjust;
            return command.next();
        },
        .loop => {
            const loop = driver.mod.commandData(command).loop;
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

pub fn setPatch(driver: *Driver, voice: Voice.Index, patch: Patch) void {
    driver.synth.voicePtr(voice).reconnect(patch.connections) catch unreachable;
    for (patch.slot_waves, 0..) |wave, slot| {
        driver.synth.voiceSlotPtr(voice, @intCast(slot)).state = .init(wave);
    }
    const part = driver.partPtr(voice);
    part.synth_params.slot = patch.slot_params;
    part.synth_params.slot_env = patch.slot_env_params;
    part.synth_params.applyTo(driver.synth, voice);
}

pub fn setLfoEnabled(driver: *Driver, voice: Voice.Index, index: Lfo.Index, enabled: bool) void {
    const lfo = driver.partPtr(voice).lfoPtr(index);
    // The LFO time is only reset when the LFO state changes from off to on.
    // This makes it so enabling an already enabled LFO is a no-op.
    if (enabled and !lfo.enabled) lfo.t = 0.0;
    lfo.enabled = enabled;
}

pub fn setLfoParams(driver: *Driver, voice: Voice.Index, index: Lfo.Index, params: Lfo) void {
    driver.partPtr(voice).lfoPtr(index).params = params;
}

pub const Part = struct {
    executing_command: Command.Index,
    next_command: Command.Index,
    delay: Ticks,
    cycle: u8,
    global_loop: Command.Index,
    loops: Loop.Stack,
    synth_params: SynthParams,
    lfos: std.EnumArray(Lfo.Index, LfoState),
    ended: bool,

    fn init(mod_part: Module.Part) Part {
        var part: Part = .{
            .executing_command = mod_part.start,
            .next_command = mod_part.start,
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

            pub const empty: Stack = .{ .loops = undefined, .len = 0 };

            pub fn shouldLoop(s: *Stack, command: Command.Index, count: LoopCount) bool {
                if (s.len == 0 or s.loops[s.len - 1].command != command) {
                    s.loops[s.len] = .{ .command = command, .iteration = 0 };
                    s.len += 1;
                }
                const loop = &s.loops[s.len - 1];
                loop.iteration +%= 1;
                const res = count == .infinite or loop.iteration < @backingInt(count);
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
                .wave = .con,
            },
            .t = 0.0,
        };

        fn process(lfo: *LfoState, sp: *SynthParams, elapsed_samples: Samples, tempo: Tempo) void {
            if (!lfo.enabled) return;
            const v = lfo.sample(elapsed_samples, tempo, sp.voice.freq);
            switch (lfo.params.target) {
                .freq => sp.voice.freq += v,
                .pan => sp.voice.pan += v,
                .vol => sp.voice.vol += v,
            }
        }

        fn sample(lfo: *LfoState, elapsed_samples: Samples, tempo: Tempo, note_freq: f32) f32 {
            const elapsed_time = switch (lfo.params.time_unit) {
                .seconds => @as(f32, @floatFromInt(@backingInt(elapsed_samples))) * zfm.sample_time,
                .ticks => @as(f32, @floatFromInt(@backingInt(elapsed_samples))) / @as(f32, @floatFromInt(@backingInt(tempo.samplesPerTick()))),
            };
            const base = base: switch (lfo.params.wave) {
                .con => 1.0,
                .sin => |params| {
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
        voice: Voice.UserParams,
        slot: [Voice.n_slots]Slot.UserParams,
        slot_env: [Voice.n_slots]Envelope.UserParams,

        pub const init: SynthParams = .{
            .voice = .init,
            .slot = @splat(.zero),
            .slot_env = @splat(.zero),
        };

        fn applyTo(sp: SynthParams, synth: *Synth, voice: Voice.Index) void {
            synth.voicePtr(voice).params = .fromUser(sp.voice.clamp());
            for (synth.voiceSlots(voice), sp.slot, sp.slot_env) |*slot, slot_params, env_params| {
                slot.params = .fromUser(slot_params.clamp(slot.state));
                slot.env.params = .fromUser(env_params.clamp());
            }
        }
    };
};

pub const Hooks = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onExecuteCommand: *const fn (ctx: *anyopaque, driver: *Driver, part: *Part, voice: Voice.Index, command: Command.Index) void,
    };

    pub const none: Hooks = .{
        .ctx = undefined,
        .vtable = &.{
            .onExecuteCommand = &noOpOnExecuteCommand,
        },
    };

    fn onExecuteCommand(h: Hooks, driver: *Driver, part: *Part, voice: Voice.Index, command: Command.Index) void {
        h.vtable.onExecuteCommand(h.ctx, driver, part, voice, command);
    }

    fn noOpOnExecuteCommand(_: *anyopaque, _: *Driver, _: *Part, _: Voice.Index, _: Command.Index) void {}
};

pub const LoggingHooks = struct {
    writer: *Writer,

    pub fn init(writer: *Writer) LoggingHooks {
        return .{ .writer = writer };
    }

    pub fn hooks(h: *LoggingHooks) Hooks {
        return .{
            .ctx = h,
            .vtable = &.{
                .onExecuteCommand = &onExecuteCommand,
            },
        };
    }

    fn onExecuteCommand(ctx: *anyopaque, driver: *Driver, _: *Part, voice: Voice.Index, command: Command.Index) void {
        const h: *LoggingHooks = @ptrCast(@alignCast(ctx));
        h.logCommand(driver, voice, command) catch {};
    }

    fn logCommand(h: *const LoggingHooks, driver: *const Driver, voice: Voice.Index, command: Command.Index) !void {
        switch (driver.mod.commandTag(command)) {
            .end, .rest, .loop => {
                // Not considered relevant for playback (implementation
                // details), so not logged. Rests, for example, are visible just
                // by looking at the `ticks` field in the other events.
            },
            inline else => |tag| {
                var out: std.json.Stringify = .{ .writer = h.writer };
                try out.beginObject();

                try out.objectField("ticks");
                try out.write(@backingInt(driver.elapsed_ticks));

                try out.objectField("part");
                try out.write(&[_]u8{driver.mod.parts[@backingInt(voice)].name});

                try out.objectField(@tagName(tag));
                const data_tag = Command.Tag.data_tags[@backingInt(tag)];
                const data = @field(driver.mod.commandData(command), @tagName(data_tag));
                if (@TypeOf(data) == void) {
                    try out.write(.{});
                } else {
                    try out.write(data);
                }

                try out.endObject();

                try h.writer.writeByte('\n');
                try h.writer.flush();
            },
        }
    }
};

const Driver = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
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
