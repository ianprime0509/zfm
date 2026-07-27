source: [:0]const u8,
pos: SourceIndex,
current_part: ?u8,
parts: std.array_hash_map.Auto(u8, Part),
patches: std.array_hash_map.Auto(StringPool.Index, Extra.Index),
macros: std.array_hash_map.Auto(StringPool.Index, SourceIndex),
extra: Extra.Wip,
strings: StringPool,

title: StringPool.Index,
composer: StringPool.Index,
arranger: StringPool.Index,
initial_tempo: Tempo,

errors: std.ArrayList(Error),
gpa: Allocator,

const eof: u8 = 0;

pub fn init(gpa: Allocator, source: [:0]const u8) Compiler {
    return .{
        .source = source,
        .pos = .start,
        .current_part = null,
        .parts = .empty,
        .patches = .empty,
        .macros = .empty,
        .extra = .empty,
        .strings = .empty,

        .title = .empty,
        .composer = .empty,
        .arranger = .empty,
        .initial_tempo = .default,

        .errors = .empty,
        .gpa = gpa,
    };
}

pub fn deinit(c: *Compiler) void {
    for (c.parts.values()) |*part| part.deinit(c.gpa);
    c.parts.deinit(c.gpa);
    c.patches.deinit(c.gpa);
    c.macros.deinit(c.gpa);
    c.extra.deinit(c.gpa);
    c.strings.deinit(c.gpa);
    c.errors.deinit(c.gpa);
    c.* = undefined;
}

pub fn sourceLocation(c: *const Compiler, span: SourceIndex.Span) SourceLocation.Span {
    const start = c.advanceSourceLocation(.start, .start, span.start);
    const end = c.advanceSourceLocation(span.start, start, span.end);
    return .{ .start = start, .end = end };
}

fn advanceSourceLocation(
    c: *const Compiler,
    start_pos: SourceIndex,
    start_loc: SourceLocation,
    end_pos: SourceIndex,
) SourceLocation {
    var pos = start_pos;
    var loc = start_loc;
    while (pos != end_pos) : (pos = pos.next()) {
        switch (c.sourceByte(pos)) {
            '\r' => {
                if (c.sourceByte(pos.next()) == '\n') pos = pos.next();
                loc.line += 1;
                loc.column = 1;
            },
            '\n' => {
                loc.line += 1;
                loc.column = 1;
            },
            else => {
                loc.column += 1;
            },
        }
    }
    return loc;
}

pub fn compile(c: *Compiler) Allocator.Error!void {
    while (c.peekByte() != eof) try c.compileLine();
    try c.finishCompilation();
}

pub fn toModule(c: *Compiler) Allocator.Error!Module {
    assert(c.errors.items.len == 0);

    var commands: Command.List = .empty;
    defer commands.deinit(c.gpa);
    const parts = try c.gpa.alloc(Module.Part, c.parts.count());
    errdefer c.gpa.free(parts);

    for (c.parts.values(), parts) |part, *mod_part| {
        const start: Command.Index = @enumFromInt(commands.len);
        try commands.ensureUnusedCapacity(c.gpa, part.commands.len + 1);
        const slice = part.commands.slice();
        for (slice.items(.tag), slice.items(.data)) |tag, data| {
            commands.appendAssumeCapacity(.{
                .tag = tag,
                .data = data,
            });
        }

        const global_loop = part.global_loop orelse part.nextCommandIndex();
        mod_part.* = .{
            .start = start,
            .global_loop = start.offset(.between(@enumFromInt(0), global_loop)),
        };
        commands.appendAssumeCapacity(.{
            .tag = .end,
            .data = .{ .none = {} },
        });
    }

    var patches = c.patches;
    errdefer patches.deinit(c.gpa);
    c.patches = .empty;
    var macros = c.macros;
    errdefer macros.deinit(c.gpa);
    c.macros = .empty;
    var extra = try c.extra.finish(c.gpa);
    errdefer extra.deinit(c.gpa);
    var strings = try c.strings.toOwnedSlice(c.gpa);
    errdefer strings.deinit(c.gpa);

    return .{
        .commands = commands.toOwnedSlice(),
        .parts = parts,
        .patches = patches,
        .macros = macros,
        .extra = extra,
        .strings = strings,

        .title = c.title,
        .composer = c.composer,
        .arranger = c.arranger,
        .initial_tempo = c.initial_tempo,
    };
}

fn compileLine(c: *Compiler) !void {
    switch (c.peekByte()) {
        '#' => try c.compileDirective(),
        '@' => try c.compilePatch(),
        '!' => try c.compileMacro(),
        'A'...'Z', 'a'...'z' => try c.compileParts(),
        else => try c.endLineAndContinuation(),
    }
}

fn finishCompilation(c: *Compiler) !void {
    c.parts.lockPointers();
    defer c.parts.unlockPointers();

    for (c.parts.keys(), c.parts.values()) |part_name, *part| {
        c.current_part = part_name;
        try c.finishPart(part);
    }
    c.current_part = null;
}

fn finishPart(c: *Compiler, part: *Part) !void {
    for (part.loops.all()) |loop| try c.reportPos(.incomplete_loop, loop.pos);
}

fn compileDirective(c: *Compiler) !void {
    assert(c.sourceByte(c.pos) == '#');
    c.skipByte();
    const name_pos = c.pos;
    const name = c.takeName() orelse {
        try c.report(.expected_name);
        c.skipLineAndContinuation();
        return;
    };
    const directive = std.meta.stringToEnum(enum {
        title,
        composer,
        arranger,
        tempo,
    }, name) orelse {
        try c.reportSpan(.invalid_directive, name_pos, c.pos);
        c.skipLineAndContinuation();
        return;
    };
    try c.expectSpace();

    switch (directive) {
        .title => {
            c.title = try c.takeText();
        },
        .composer => {
            c.composer = try c.takeText();
        },
        .arranger => {
            c.arranger = try c.takeText();
        },
        .tempo => {
            if (!c.continueLine()) {
                try c.report(.expected_param);
                return;
            }
            const tempo = try c.takeNumber(Tempo) orelse {
                try c.report(.expected_param);
                c.skipLineAndContinuation();
                return;
            };
            c.initial_tempo = tempo;
            try c.endLineAndContinuation();
        },
    }
}

fn compilePatch(c: *Compiler) !void {
    assert(c.sourceByte(c.pos) == '@');
    c.skipByte();
    const name = c.takeName() orelse {
        try c.report(.expected_name);
        c.skipLineAndContinuation();
        return;
    };

    const connections = try c.takeConnections() orelse {
        try c.report(.unexpected_end_of_patch);
        return;
    };

    var slot_waves: [Voice.n_slots]Slot.Wave = @splat(.sine);
    var slot_params: [Voice.n_slots]Slot.Params = @splat(.zero);
    var slot_env_params: [Voice.n_slots]Envelope.Params = @splat(.zero);
    for (&slot_waves, &slot_params, &slot_env_params) |*wave, *params, *env_params| {
        if (!c.canContinueLine()) break;
        assert(c.continueLine());
        wave.* = try c.takeEnum(Slot.Wave) orelse return c.report(.unexpected_end_of_patch);
        inline for (@typeInfo(Slot.Params).@"struct".field_names) |field| {
            if (!c.continueLine()) return c.report(.unexpected_end_of_patch);
            const is_ws = comptime std.mem.eql(u8, field, "ws");
            const uses_param = !is_ws or wave.usesWs();
            if (uses_param) {
                @field(params, field) = try c.takeNumber(f32) orelse {
                    try c.report(.unexpected_end_of_patch);
                    c.skipLineAndContinuation();
                    return;
                };
            } else {
                @field(params, field) = 0.0;
            }
        }
        inline for (@typeInfo(Envelope.Params).@"struct".field_names) |field| {
            if (!c.continueLine()) return c.report(.unexpected_end_of_patch);
            @field(env_params, field) = try c.takeNumber(f32) orelse {
                try c.report(.unexpected_end_of_patch);
                c.skipLineAndContinuation();
                return;
            };
        }
    }

    try c.endLineAndContinuation();

    const patch: Patch = .{
        .connections = connections,
        .slot_waves = slot_waves,
        .slot_params = slot_params,
        .slot_env_params = slot_env_params,
    };
    const index = c.extra.currentIndex();
    try c.extra.encode(c.gpa, patch);
    const name_str = try c.strings.intern(c.gpa, name);
    try c.patches.put(c.gpa, name_str, index);
}

fn takeConnections(c: *Compiler) !?Voice.Connections {
    var res: Voice.Connections = .none;
    var last: ?Voice.SlotIndex = null;
    while (true) {
        if (!c.continueLine()) return null;
        switch (c.peekByte()) {
            ',' => {
                c.skipByte();
                last = null;
            },
            '.' => {
                c.skipByte();
                return res;
            },
            else => {
                const to = try c.takeNumber(Voice.SlotIndex) orelse {
                    c.skipLineAndContinuation();
                    return null;
                };
                if (last) |from| res.connect(from, to);
                last = to;
            },
        }
    }
}

fn compileMacro(c: *Compiler) !void {
    assert(c.sourceByte(c.pos) == '!');
    c.skipByte();
    const name = c.takeName() orelse {
        try c.report(.expected_name);
        c.skipLineAndContinuation();
        return;
    };
    try c.expectSpace();

    const name_str = try c.strings.intern(c.gpa, name);
    try c.macros.put(c.gpa, name_str, c.pos);
    // Skip the actual macro definition: macros are processed only when used.
    c.skipLineAndContinuation();
}

fn compileParts(c: *Compiler) !void {
    const part_names = try c.takePartNames();
    if (!c.continueLine()) return;
    const start = c.pos;
    for (part_names) |part_name| {
        if (!isPartName(part_name)) continue;
        const gop = try c.parts.getOrPut(c.gpa, part_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = .init;
        }
        const part = gop.value_ptr;

        c.current_part = part_name;
        defer c.current_part = null;
        c.parts.lockPointers();
        defer c.parts.unlockPointers();
        c.pos = start;
        try c.compilePart(part);
    }
}

fn compilePart(c: *Compiler, part: *Part) !void {
    var call_stack: CallStack = .empty;
    while (true) {
        while (c.continueLine()) try c.compileCommand(part, &call_stack);
        c.pos = call_stack.returnTo() orelse break;
    }
}

fn compileCommand(c: *Compiler, part: *Part, call_stack: *CallStack) !void {
    const start_pos = c.pos;
    switch (c.peekByte()) {
        'a'...'g' => {
            const note = c.takeNote(part).?;
            const length = try c.takeNoteLength() orelse part.default_length;
            try part.addCommand(c.gpa, .key_on, .{ .freq = note });
            try part.addCommand(c.gpa, .rest, .{ .ticks = length });
            try part.addCommand(c.gpa, .key_off, .{ .none = {} });
        },
        'r' => {
            c.skipByte();
            const length = try c.takeNoteLength() orelse part.default_length;
            try part.addCommand(c.gpa, .rest, .{ .ticks = length });
        },
        '.' => {
            c.skipByte();
            const commands = part.commands.slice();
            const tags = commands.items(.tag);
            const datas = commands.items(.data);
            const rest = previousRestIndex(tags) orelse return c.reportSpan(.last_command_not_note, start_pos, c.pos);
            datas[rest].ticks = datas[rest].ticks.dot() catch return c.reportSpan(.cannot_dot, start_pos, c.pos);
        },
        'l' => {
            c.skipByte();
            part.default_length = try c.takeNoteLength() orelse return c.report(.expected_param);
        },
        '-', '+' => |op| {
            c.skipByte();
            const length = try c.takeNoteLength() orelse return c.report(.expected_param);
            const commands = part.commands.slice();
            const tags = commands.items(.tag);
            const datas = commands.items(.data);
            const rest = previousRestIndex(tags) orelse return c.reportSpan(.last_command_not_note, start_pos, c.pos);
            datas[rest].ticks = switch (op) {
                '+' => @enumFromInt(@intFromEnum(datas[rest].ticks) +| @intFromEnum(length)),
                '-' => @enumFromInt(@intFromEnum(datas[rest].ticks) -| @intFromEnum(length)),
                else => unreachable,
            };
        },
        '&' => {
            // TODO: also support &n to extend note by length n
            c.skipByte();
            const tags = part.commands.items(.tag);
            if (tags.len < 1 or tags[tags.len - 1] != .key_off) {
                return c.reportSpan(.last_command_not_note, start_pos, c.pos);
            }
            part.commands.len -= 1;
        },
        'o' => {
            c.skipByte();
            const n = try c.takeNumber(u4) orelse return c.report(.expected_param);
            part.octave = @floatFromInt(n);
        },
        '>' => {
            c.skipByte();
            part.octave += 1.0;
        },
        '<' => {
            c.skipByte();
            part.octave -= 1.0;
        },
        '@' => {
            c.skipByte();
            const name_pos = c.pos;
            const name = c.takeName() orelse return c.report(.expected_name);
            const name_str = c.strings.find(name) orelse return c.reportSpan(.undefined_patch, name_pos, c.pos);
            const index = c.patches.get(name_str) orelse return c.reportSpan(.undefined_patch, name_pos, c.pos);
            try part.addCommand(c.gpa, .set_patch, .{ .extra = index });
        },
        '!' => {
            c.skipByte();
            const name_pos = c.pos;
            const name = c.takeName() orelse return c.report(.expected_name);
            const name_str = c.strings.find(name) orelse return c.reportSpan(.undefined_macro, name_pos, c.pos);
            const call_pos = c.macros.get(name_str) orelse return c.reportSpan(.undefined_macro, name_pos, c.pos);
            call_stack.callFrom(c.pos) catch return c.reportSpan(.macro_too_deep, call_pos, c.pos);
            c.pos = call_pos;
        },
        'v' => {
            c.skipByte();
            const tag: Command.Tag = switch (c.peekByte()) {
                '+', '-' => .add_volume,
                else => .set_volume,
            };
            const amount = try c.takeNumber(f32) orelse return c.report(.expected_param);
            try part.addCommand(c.gpa, tag, .{ .amount = amount });
        },
        'L' => {
            c.skipByte();
            part.global_loop = part.nextCommandIndex();
        },
        '[' => {
            c.skipByte();
            part.loops.push(.{ .start = part.nextCommandIndex(), .pos = start_pos }) catch
                return c.reportSpan(.loop_too_deep, start_pos, c.pos);
        },
        ']' => {
            c.skipByte();
            const count: LoopCount = try c.takeNumber(LoopCount) orelse .infinite;
            if (part.loops.pop()) |loop| {
                try part.addCommand(c.gpa, .loop, .{ .loop = .{
                    .branch = .between(part.nextCommandIndex(), loop.start),
                    .count = count,
                } });
            } else {
                return c.reportSpan(.not_in_loop, start_pos, c.pos);
            }
        },
        '{' => {
            c.skipByte();
            try c.compilePortamento(part);
        },
        '*' => {
            c.skipByte();
            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            try part.addCommand(c.gpa, .toggle_lfo, .{ .lfo = .user(lfo) });
        },
        'M' => {
            c.skipByte();
            try c.compileLfoCommand(part, start_pos);
        },
        '_' => {
            c.skipByte();
            switch (c.peekByte()) {
                '{' => {
                    c.skipByte();
                    try c.compileKeyChange(part);
                },
                else => {
                    c.skipByte();
                    try c.reportSpan(.invalid_command, start_pos, c.pos);
                },
            }
        },
        else => {
            c.skipByte();
            try c.reportSpan(.invalid_command, start_pos, c.pos);
        },
    }
}

fn previousRestIndex(tags: []const Command.Tag) ?usize {
    if (tags.len >= 1 and tags[tags.len - 1] == .rest) return tags.len - 1;
    if (tags.len >= 2 and tags[tags.len - 1] == .key_off and tags[tags.len - 2] == .rest) return tags.len - 2;
    return null;
}

fn compilePortamento(c: *Compiler, part: *Part) !void {
    var from: f32 = 0.0;
    var to: f32 = 0.0;
    var state: enum { start, after_from, after_to } = .start;
    while (true) switch (c.peekByte()) {
        '>' => {
            c.skipByte();
            part.octave += 1.0;
        },
        '<' => {
            c.skipByte();
            part.octave -= 1.0;
        },
        '}' => {
            if (state != .after_to) try c.report(.expected_note);
            c.skipByte();
            break;
        },
        'a'...'g' => switch (state) {
            .start => {
                from = c.takeNote(part).?;
                state = .after_from;
            },
            .after_from => {
                to = c.takeNote(part).?;
                state = .after_to;
            },
            .after_to => {
                try c.reportUnexpectedCharacter();
                c.skipByte();
            },
        },
        else => {
            try c.reportUnexpectedCharacter();
            c.skipByte();
        },
    };
    const length = try c.takeNoteLength() orelse part.default_length;

    try c.addSetLfoTargetCommand(part, .porta, .freq);
    try c.addSetLfoSizeCommand(part, .porta, .{ .scale = from, .offset = -from });
    try c.addSetLfoWaveCommand(part, .porta, .{ .exp = .{
        .mul = (@log2(to) - @log2(from)) / @as(f32, @floatFromInt(@intFromEnum(length))),
    } });
    try part.addCommand(c.gpa, .toggle_lfo, .{ .lfo = .porta });
    try part.addCommand(c.gpa, .key_on, .{ .freq = from });
    try part.addCommand(c.gpa, .rest, .{ .ticks = length });
    try part.addCommand(c.gpa, .toggle_lfo, .{ .lfo = .porta });
    try part.addCommand(c.gpa, .key_on, .{ .freq = to });
    try part.addCommand(c.gpa, .key_off, .{ .none = {} });
}

fn compileLfoCommand(c: *Compiler, part: *Part, start_pos: SourceIndex) !void {
    switch (c.peekByte()) {
        'T' => {
            c.skipByte();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const target = try c.takeEnum(Lfo.Target) orelse return c.report(.expected_param);

            try c.addSetLfoTargetCommand(part, .user(lfo), target);
        },
        'S' => {
            c.skipByte();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const scale = try c.takeNumber(f32) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const offset = try c.takeNumber(f32) orelse return c.report(.expected_param);

            try c.addSetLfoSizeCommand(part, .user(lfo), .{ .scale = scale, .offset = offset });
        },
        'W' => {
            c.skipByte();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const wave_tag = try c.takeEnum(Lfo.Wave.Tag) orelse return c.report(.expected_param);
            const wave: Lfo.Wave = wave: switch (wave_tag) {
                .constant => .constant,
                .sine => {
                    if (!c.takeComma()) return c.report(.expected_param);
                    const freq = try c.takeNumber(f32) orelse return c.report(.expected_param);
                    break :wave .{ .sine = .{ .freq = freq } };
                },
                .exp => {
                    if (!c.takeComma()) return c.report(.expected_param);
                    const mul = try c.takeNumber(f32) orelse return c.report(.expected_param);
                    break :wave .{ .exp = .{ .mul = mul } };
                },
            };

            try c.addSetLfoWaveCommand(part, .user(lfo), wave);
        },
        'O' => {
            c.skipByte();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const trigger = try c.takeEnum(Lfo.Trigger) orelse return c.report(.expected_param);

            try c.addSetLfoTriggerCommand(part, .user(lfo), trigger);
        },
        'A' => {
            c.skipByte();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const adjust = try c.takeBoolean() orelse return c.report(.expected_param);

            try c.addSetLfoAdjustCommand(part, .user(lfo), adjust);
        },
        else => {
            c.skipByte();
            try c.reportSpan(.invalid_command, start_pos, c.pos);
        },
    }
}

fn compileKeyChange(c: *Compiler, part: *Part) !void {
    while (true) switch (c.peekByte()) {
        '+', '-', '=' => {
            const accidentals = c.takeAccidentals().?;
            while (c.takeNoteName()) |note| part.default_accidentals.set(note, accidentals);
        },
        '}' => {
            c.skipByte();
            break;
        },
        else => {
            try c.reportUnexpectedCharacter();
            c.skipByte();
        },
    };
}

fn addSetLfoTargetCommand(c: *Compiler, part: *Part, index: Lfo.Index, target: Lfo.Target) !void {
    try part.addCommand(c.gpa, .set_lfo_target, .{ .lfo_target = .{
        .index = index,
        .target = target,
    } });
}

fn addSetLfoSizeCommand(c: *Compiler, part: *Part, index: Lfo.Index, size: Lfo.Size) !void {
    const data = c.extra.currentIndex();
    try c.extra.encode(c.gpa, size);
    try part.addCommand(c.gpa, .set_lfo_size, .{ .lfo_data = .{
        .index = index,
        .data = data,
    } });
}

fn addSetLfoWaveCommand(c: *Compiler, part: *Part, index: Lfo.Index, wave: Lfo.Wave) !void {
    const data = c.extra.currentIndex();
    try c.extra.encode(c.gpa, wave);
    try part.addCommand(c.gpa, .set_lfo_wave, .{ .lfo_data = .{
        .index = index,
        .data = data,
    } });
}

fn addSetLfoTriggerCommand(c: *Compiler, part: *Part, index: Lfo.Index, trigger: Lfo.Trigger) !void {
    try part.addCommand(c.gpa, .set_lfo_trigger, .{ .lfo_trigger = .{
        .index = index,
        .trigger = trigger,
    } });
}

fn addSetLfoAdjustCommand(c: *Compiler, part: *Part, index: Lfo.Index, adjust: bool) !void {
    try part.addCommand(c.gpa, .set_lfo_adjust, .{ .lfo_adjust = .{
        .index = index,
        .adjust = adjust,
    } });
}

fn sourceByte(c: *const Compiler, index: SourceIndex) u8 {
    return c.source[@intFromEnum(index)];
}

fn sourceSlice(c: *const Compiler, start: SourceIndex, end: SourceIndex) []const u8 {
    return c.source[@intFromEnum(start)..@intFromEnum(end)];
}

fn peekByte(c: *const Compiler) u8 {
    return c.source[@intFromEnum(c.pos)];
}

fn skipByte(c: *Compiler) void {
    if (@intFromEnum(c.pos) < c.source.len) c.pos = c.pos.next();
}

fn expectByte(c: *Compiler, b: u8) !void {
    if (c.peekByte() != b) {
        try c.reportData(.expected_char, .{ .char = b });
        return;
    }
    c.skipByte();
}

fn expectSpace(c: *Compiler) !void {
    switch (c.peekByte()) {
        ' ', '\t' => c.skipByte(),
        '\r', '\n' => {},
        else => try c.report(.expected_space),
    }
}

fn skipLine(c: *Compiler) void {
    var eol = std.mem.findAnyPos(u8, c.source, @intFromEnum(c.pos), "\r\n") orelse {
        c.pos = @enumFromInt(c.source.len);
        return;
    };
    if (c.source[eol] == '\r' and c.source[eol + 1] == '\n') eol += 1;
    c.pos = @enumFromInt(eol + 1);
}

fn skipLineAndContinuation(c: *Compiler) void {
    while (c.continueLine()) {
        c.skipLine();
        // After skipping the line, if the character we're looking at isn't a
        // space (or comment), it means we've exhausted the continuation.
        switch (c.peekByte()) {
            ' ', '\t', '\r', '\n', ';' => {},
            else => return,
        }
    }
}

fn continueLine(c: *Compiler) bool {
    var indented = true;
    while (true) switch (c.peekByte()) {
        eof => return false,
        ';' => {
            c.skipLine();
            indented = false;
        },
        ' ', '\t' => {
            c.skipByte();
            indented = true;
        },
        '\r', '\n' => {
            c.skipByte();
            indented = false;
        },
        else => return indented,
    };
}

fn canContinueLine(c: *Compiler) bool {
    const pos = c.pos;
    defer c.pos = pos;
    return c.continueLine();
}

fn endLineAndContinuation(c: *Compiler) !void {
    if (c.continueLine()) {
        try c.reportUnexpectedCharacter();
        c.skipLineAndContinuation();
    }
}

fn takeComma(c: *Compiler) bool {
    if (c.peekByte() == ',') {
        c.skipByte();
        return true;
    } else {
        return false;
    }
}

fn takeText(c: *Compiler) !StringPool.Index {
    const start = try c.strings.startWriting(c.gpa);
    while (true) {
        const line_start = c.pos;
        c.skipLine();
        const line_end = c.pos;
        const line = std.mem.trim(u8, c.sourceSlice(line_start, line_end), " \t\r\n");
        if (line.len > 0) {
            if (c.strings.writingIndex() != start) try c.strings.bytes.append(c.gpa, ' ');
            try c.strings.bytes.appendSlice(c.gpa, line);
        }
        switch (c.peekByte()) {
            ' ', '\t', '\r', '\n' => {}, // continuation line
            else => break,
        }
    }
    return try c.strings.finishWriting(c.gpa, start);
}

fn skipMatching(c: *Compiler, pred: fn (u8) bool) void {
    while (pred(c.peekByte())) c.skipByte();
}

fn isNameByte(b: u8) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
        else => false,
    };
}

fn takeName(c: *Compiler) ?[]const u8 {
    const start = c.pos;
    c.skipMatching(isNameByte);
    return if (c.pos != start) c.sourceSlice(start, c.pos) else null;
}

fn takeEnum(c: *Compiler, T: type) !?T {
    const pos = c.pos;
    const name = c.takeName() orelse return null;
    return std.meta.stringToEnum(T, name) orelse {
        try c.reportPos(.invalid_enum, pos);
        return null;
    };
}

fn isUnsignedIntByte(b: u8) bool {
    return switch (b) {
        '0'...'9' => true,
        else => false,
    };
}

fn isSignedIntByte(b: u8) bool {
    return switch (b) {
        '+', '-', '0'...'9' => true,
        else => false,
    };
}

fn isFloatByte(b: u8) bool {
    return switch (b) {
        '+', '-', '0'...'9', '.' => true,
        else => false,
    };
}

fn takeNoteLength(c: *Compiler) !?Ticks {
    // TODO: raw tick length (%)
    const start = c.pos;
    const divisor = try c.takeNumber(u32) orelse return null;
    return Ticks.zenlen.fraction(divisor) catch {
        try c.reportPos(.indivisible_note_length, start);
        return null;
    };
}

fn takeBoolean(c: *Compiler) !?bool {
    return (try c.takeNumber(u1) orelse return null) != 0;
}

fn takeNumber(c: *Compiler, T: type) !?T {
    const start = c.pos;
    switch (@typeInfo(T)) {
        .@"enum" => |@"enum"| {
            return @enumFromInt(try c.takeNumber(@"enum".tag_type) orelse return null);
        },
        .@"struct" => |@"struct"| {
            comptime assert(@"struct".field_names.len == 1);
            var s: T = undefined;
            @field(s, @"struct".field_names[0]) = try c.takeNumber(@"struct".field_types[0]) orelse return null;
            return s;
        },
        .int => |int| switch (int.signedness) {
            .unsigned => {
                c.skipMatching(isUnsignedIntByte);
                if (c.pos == start) return null;
                return std.fmt.parseUnsigned(T, c.sourceSlice(start, c.pos), 10) catch {
                    try c.reportDataPos(.invalid_int, .{ .int = int }, start);
                    return null;
                };
            },
            .signed => {
                c.skipMatching(isSignedIntByte);
                if (c.pos == start) return null;
                return std.fmt.parseInt(T, c.sourceSlice(start, c.pos), 10) catch {
                    try c.reportDataPos(.invalid_int, .{ .int = int }, start);
                    return null;
                };
            },
        },
        .float => {
            c.skipMatching(isFloatByte);
            if (c.pos == start) return null;
            return std.fmt.parseFloat(T, c.sourceSlice(start, c.pos)) catch {
                try c.reportPos(.invalid_float, start);
                return null;
            };
        },
        else => comptime unreachable,
    }
}

fn isPartName(b: u8) bool {
    return switch (b) {
        'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

fn takePartNames(c: *Compiler) ![]const u8 {
    const start = c.pos;
    while (true) {
        c.skipMatching(isPartName);
        switch (c.peekByte()) {
            eof, ' ', '\t', '\r', '\n' => break,
            else => {
                try c.reportSpan(.invalid_part_name, c.pos, c.pos.next());
                c.skipByte();
            },
        }
    }
    return c.sourceSlice(start, c.pos);
}

fn takeNote(c: *Compiler, part: *const Part) ?f32 {
    const note = c.takeNoteName() orelse return null;
    const accidentals = c.takeAccidentals();
    return part.noteFreq(note, accidentals);
}

fn takeNoteName(c: *Compiler) ?Note {
    const note = std.meta.stringToEnum(Note, &.{c.peekByte()}) orelse return null;
    c.skipByte();
    return note;
}

fn takeAccidentals(c: *Compiler) ?f32 {
    var res: ?f32 = null;
    while (true) switch (c.peekByte()) {
        '=' => {
            res = 0.0;
            c.skipByte();
        },
        '+' => {
            res = (res orelse 0.0) + 1.0;
            c.skipByte();
        },
        '-' => {
            res = (res orelse 0.0) - 1.0;
            c.skipByte();
        },
        else => break,
    };
    return res;
}

fn report(c: *Compiler, tag: Error.Tag) !void {
    try c.reportDataSpan(tag, .{ .none = {} }, c.pos, c.pos);
}

fn reportPos(c: *Compiler, tag: Error.Tag, pos: SourceIndex) !void {
    try c.reportDataSpan(tag, .{ .none = {} }, pos, pos);
}

fn reportSpan(c: *Compiler, tag: Error.Tag, start: SourceIndex, end: SourceIndex) !void {
    try c.reportDataSpan(tag, .{ .none = {} }, start, end);
}

fn reportData(c: *Compiler, tag: Error.Tag, data: Error.Data) !void {
    try c.reportDataSpan(tag, data, c.pos, c.pos);
}

fn reportDataPos(c: *Compiler, tag: Error.Tag, data: Error.Data, pos: SourceIndex) !void {
    try c.reportDataSpan(tag, data, pos, pos);
}

fn reportDataSpan(c: *Compiler, tag: Error.Tag, data: Error.Data, start: SourceIndex, end: SourceIndex) !void {
    try c.errors.append(c.gpa, .{
        .tag = tag,
        .data = data,
        .span = .{ .start = start, .end = end },
        .part = c.current_part,
    });
}

fn reportUnexpectedCharacter(c: *Compiler) !void {
    // TODO: this (and other places) need to be audited to ensure we properly skip entire codepoints, not bytes
    try c.reportSpan(.unexpected_character, c.pos, c.pos.next());
}

const Note = enum { c, d, e, f, g, a, b };

const Part = struct {
    commands: Command.List,
    octave: f32,
    default_accidentals: std.EnumArray(Note, f32),
    default_length: Ticks,
    global_loop: ?Command.Index,
    loops: Loop.Stack,

    const init: Part = .{
        .commands = .empty,
        .octave = 4.0,
        .default_accidentals = .initFill(0.0),
        .default_length = Ticks.zenlen.fraction(4) catch unreachable,
        .global_loop = null,
        .loops = .empty,
    };

    fn deinit(part: *Part, gpa: Allocator) void {
        part.commands.deinit(gpa);
        part.* = undefined;
    }

    fn nextCommandIndex(part: *const Part) Command.Index {
        return @enumFromInt(part.commands.len);
    }

    fn addCommand(part: *Part, gpa: Allocator, tag: Command.Tag, data: Command.Data) !void {
        try part.commands.append(gpa, .{
            .tag = tag,
            .data = data,
        });
    }

    fn noteFreq(part: *const Part, note: Note, explicit_accidentals: ?f32) f32 {
        const note_offset: f32 = switch (note) {
            .c => 0.0,
            .d => 2.0,
            .e => 4.0,
            .f => 5.0,
            .g => 7.0,
            .a => 9.0,
            .b => 11.0,
        };
        const midi_base = 12.0 + 12.0 * part.octave + note_offset;
        const accidentals = explicit_accidentals orelse part.default_accidentals.get(note);
        const midi = midi_base + accidentals;
        return 440.0 * std.math.pow(f32, 2.0, (midi - 69.0) / 12.0);
    }

    const Loop = struct {
        start: Command.Index,
        pos: SourceIndex,

        const Stack = struct {
            loops: [max_loop_depth]Loop,
            len: std.math.IntFittingRange(0, max_loop_depth),

            const empty: Stack = .{ .loops = undefined, .len = 0 };

            fn all(s: *Stack) []Loop {
                return s.loops[0..@min(s.loops.len, s.len)];
            }

            fn push(s: *Stack, loop: Loop) error{Overflow}!void {
                if (s.len >= s.loops.len) return error.Overflow;
                s.loops[s.len] = loop;
                s.len += 1;
            }

            fn pop(s: *Stack) ?Loop {
                if (s.len == 0) return null;
                s.len -= 1;
                return s.loops[s.len];
            }
        };
    };
};

const CallStack = struct {
    ret_addrs: [max_macro_depth]SourceIndex,
    len: std.math.IntFittingRange(0, max_macro_depth),

    const empty: CallStack = .{ .ret_addrs = undefined, .len = 0 };

    fn callFrom(s: *CallStack, ret_addr: SourceIndex) error{Overflow}!void {
        if (s.len == s.ret_addrs.len) return error.Overflow;
        s.ret_addrs[s.len] = ret_addr;
        s.len += 1;
    }

    fn returnTo(s: *CallStack) ?SourceIndex {
        if (s.len == 0) return null;
        s.len -= 1;
        return s.ret_addrs[s.len];
    }
};

pub const Error = struct {
    tag: Tag,
    data: Data,
    span: SourceIndex.Span,
    part: ?u8,

    pub const Tag = enum {
        unexpected_character,
        unexpected_end_of_patch,
        expected_name,
        expected_param,
        expected_note,
        expected_char,
        expected_space,
        invalid_part_name,
        invalid_command,
        invalid_directive,
        invalid_enum,
        invalid_int,
        invalid_float,
        undefined_patch,
        undefined_macro,
        macro_too_deep,
        indivisible_note_length,
        last_command_not_note,
        cannot_dot,
        not_in_loop,
        loop_too_deep,
        incomplete_loop,
    };

    pub const Data = union {
        none: void,
        char: u8,
        int: std.lang.Type.Int,
    };

    pub fn format(err: Error, w: *Writer) Writer.Error!void {
        switch (err.tag) {
            .unexpected_character => try w.print("unexpected character", .{}),
            .unexpected_end_of_patch => try w.print("unexpected end of patch", .{}),
            .expected_name => try w.print("expected name", .{}),
            .expected_param => try w.print("expected parameter", .{}),
            .expected_note => try w.print("expected note", .{}),
            .expected_char => try w.print("expected '{c}'", .{err.data.char}),
            .expected_space => try w.print("expected space or tab", .{}),
            .invalid_part_name => try w.print("invalid part name", .{}),
            .invalid_command => try w.print("invalid command", .{}),
            .invalid_directive => try w.print("invalid directive", .{}),
            .invalid_enum => try w.print("invalid enum value", .{}),
            .invalid_int => try w.print("invalid integer for type {c}{}", .{ @as(u8, switch (err.data.int.signedness) {
                .signed => 'i',
                .unsigned => 'u',
            }), err.data.int.bits }),
            .invalid_float => try w.print("invalid float", .{}),
            .undefined_patch => try w.print("undefined patch", .{}),
            .undefined_macro => try w.print("undefined macro", .{}),
            .macro_too_deep => try w.print("macro call stack too deep", .{}),
            .indivisible_note_length => try w.print("note length cannot be represented as ticks", .{}),
            .last_command_not_note => try w.print("last command was not a note", .{}),
            .cannot_dot => try w.print("note length cannot be dotted", .{}),
            .not_in_loop => try w.print("not in a loop", .{}),
            .loop_too_deep => try w.print("loop nesting too deep", .{}),
            .incomplete_loop => try w.print("incomplete loop at end of part", .{}),
        }
    }
};

const Compiler = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const assert = std.debug.assert;
const zfm = @import("./zfm.zig");
const Driver = zfm.Driver;
const Module = zfm.Module;
const SourceIndex = Module.SourceIndex;
const SourceLocation = Module.SourceLocation;
const Command = Module.Command;
const Patch = Module.Patch;
const Lfo = Module.Lfo;
const Extra = Module.Extra;
const Ticks = Module.Ticks;
const Tempo = Module.Tempo;
const LoopCount = Module.LoopCount;
const max_loop_depth = Module.max_loop_depth;
const max_macro_depth = Module.max_macro_depth;
const Synth = zfm.Synth;
const Voice = Synth.Voice;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
const StringPool = @import("./StringPool.zig");
