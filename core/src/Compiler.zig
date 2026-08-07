source: [:0]const u8,
pos: SourceIndex,
current_part: ?u8,
current_start: SourceIndex,
parts: std.array_hash_map.Auto(u8, Part),
patches: std.array_hash_map.Auto(StringPool.Index, Patch.Entry),
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
    assert(std.unicode.utf8ValidateSlice(source));
    return .{
        .source = source,
        .pos = .start,
        .current_part = null,
        .current_start = undefined,
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
    while (pos != end_pos) {
        switch (c.sourceChar(pos)) {
            '\r' => {
                if (c.sourceChar(pos.plusBytes(1)) == '\n') pos = pos.plusBytes(1);
                loc.line += 1;
                loc.column = 1;
                pos = pos.plusBytes(1);
            },
            '\n' => {
                loc.line += 1;
                loc.column = 1;
                pos = pos.plusBytes(1);
            },
            else => |ch| {
                loc.column += 1;
                pos = pos.plusBytes(std.unicode.utf8CodepointSequenceLength(ch) catch unreachable);
            },
        }
    }
    return loc;
}

pub fn compile(c: *Compiler) Allocator.Error!void {
    while (c.peekChar() != eof) try c.compileLine();
    try c.finishCompilation();
}

pub fn toModule(c: *Compiler) Allocator.Error!Module {
    assert(c.errors.items.len == 0);

    var commands: Command.List = .empty;
    defer commands.deinit(c.gpa);
    const parts = try c.gpa.alloc(Module.Part, c.parts.count());
    errdefer c.gpa.free(parts);

    for (c.parts.values(), parts) |part, *mod_part| {
        const start: Command.Index = @fromBackingInt(@intCast(commands.len));
        try commands.ensureUnusedCapacity(c.gpa, part.commands.len + 1);
        const slice = part.commands.slice();
        for (slice.items(.tag), slice.items(.data), slice.items(.span)) |tag, data, span| {
            commands.appendAssumeCapacity(.{
                .tag = tag,
                .data = data,
                .span = span,
            });
        }

        const global_loop = part.global_loop orelse part.nextCommandIndex();
        mod_part.* = .{
            .start = start,
            .global_loop = start.offset(.between(@fromBackingInt(0), global_loop)),
        };
        commands.appendAssumeCapacity(.{
            .tag = .end,
            .data = .{ .none = {} },
            .span = undefined,
        });
    }

    const patches = try c.gpa.dupe(Patch.Entry, c.patches.values());
    errdefer c.gpa.free(patches);

    var extra = try c.extra.finish(c.gpa);
    errdefer extra.deinit(c.gpa);

    var strings = try c.strings.toOwnedSlice(c.gpa);
    errdefer strings.deinit(c.gpa);

    return .{
        .commands = commands.toOwnedSlice(),
        .parts = parts,
        .patches = patches,
        .extra = extra,
        .strings = strings,

        .title = c.title,
        .composer = c.composer,
        .arranger = c.arranger,
        .initial_tempo = c.initial_tempo,
    };
}

fn compileLine(c: *Compiler) !void {
    switch (c.peekChar()) {
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
    assert(c.sourceChar(c.pos) == '#');
    c.skipChar();
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
    assert(c.sourceChar(c.pos) == '@');
    const start_pos = c.pos;
    c.skipChar();
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
    try c.patches.put(c.gpa, name_str, .{
        .name = name_str,
        .span = .{ .start = start_pos, .end = c.pos },
        .index = index,
    });
}

fn takeConnections(c: *Compiler) !?Voice.Connections {
    var res: Voice.Connections = .none;
    var last: ?Voice.SlotIndex = null;
    while (true) {
        if (!c.continueLine()) return null;
        switch (c.peekChar()) {
            ',' => {
                c.skipChar();
                last = null;
            },
            '.' => {
                c.skipChar();
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
    assert(c.sourceChar(c.pos) == '!');
    c.skipChar();
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
        if (!isPartNameChar(part_name)) continue;
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
    c.current_start = c.pos;
    switch (c.peekChar()) {
        'a'...'g' => {
            const note = c.takeNote(part).?;
            const length = try c.takeNoteLength(part);
            try part.addCommand(c, .key_on, .{ .freq = note });
            try part.addCommand(c, .rest, .{ .ticks = length });
            try part.addCommand(c, .key_off, .{ .none = {} });
        },
        'r' => {
            c.skipChar();
            const length = try c.takeNoteLength(part);
            try part.addCommand(c, .rest, .{ .ticks = length });
        },
        'l' => {
            c.skipChar();
            part.default_length = try c.takeNoteLength(part);
        },
        '&' => {
            c.skipChar();

            const tags = part.commands.items(.tag);
            if (tags.len < 1 or tags[tags.len - 1] != .key_off) {
                return c.reportSpan(.last_command_not_note, c.current_start, c.pos);
            }
            part.commands.len -= 1;
        },
        'o' => {
            c.skipChar();
            const n = try c.takeNumber(u4) orelse return c.report(.expected_param);
            part.octave = @floatFromInt(n);
        },
        '>' => {
            c.skipChar();
            part.octave += 1.0;
        },
        '<' => {
            c.skipChar();
            part.octave -= 1.0;
        },
        '@' => {
            c.skipChar();
            const name_pos = c.pos;
            const name = c.takeName() orelse return c.report(.expected_name);
            const name_str = c.strings.find(name) orelse return c.reportSpan(.undefined_patch, name_pos, c.pos);
            const entry = c.patches.get(name_str) orelse return c.reportSpan(.undefined_patch, name_pos, c.pos);
            try part.addCommand(c, .set_patch, .{ .extra = entry.index });
        },
        '!' => {
            c.skipChar();
            const name_pos = c.pos;
            const name = c.takeName() orelse return c.report(.expected_name);
            const name_str = c.strings.find(name) orelse return c.reportSpan(.undefined_macro, name_pos, c.pos);
            const call_pos = c.macros.get(name_str) orelse return c.reportSpan(.undefined_macro, name_pos, c.pos);
            call_stack.callFrom(c.pos) catch return c.reportSpan(.macro_too_deep, call_pos, c.pos);
            c.pos = call_pos;
        },
        'v' => {
            c.skipChar();
            const tag: Command.Tag = switch (c.peekChar()) {
                '+', '-' => .add_volume,
                else => .set_volume,
            };
            const amount = try c.takeNumber(f32) orelse return c.report(.expected_param);
            try part.addCommand(c, tag, .{ .amount = amount });
        },
        't' => {
            c.skipChar();
            const tag: Command.Tag = switch (c.peekChar()) {
                '+', '-' => .add_tempo,
                else => .set_tempo,
            };
            const amount = try c.takeNumber(f32) orelse return c.report(.expected_param);
            try part.addCommand(c, tag, .{ .amount = amount });
        },
        'p' => {
            c.skipChar();
            const amount = try c.takeNumber(f32) orelse return c.report(.expected_param);
            try part.addCommand(c, .set_pan, .{ .amount = amount });
        },
        'L' => {
            c.skipChar();
            part.global_loop = part.nextCommandIndex();
        },
        '[' => {
            c.skipChar();
            part.loops.push(.{ .start = part.nextCommandIndex(), .pos = c.current_start }) catch
                return c.reportSpan(.loop_too_deep, c.current_start, c.pos);
        },
        ']' => {
            c.skipChar();
            const count: LoopCount = try c.takeNumber(LoopCount) orelse .infinite;
            if (part.loops.pop()) |loop| {
                try part.addCommand(c, .loop, .{ .loop = .{
                    .branch = .between(part.nextCommandIndex(), loop.start),
                    .count = count,
                } });
            } else {
                return c.reportSpan(.not_in_loop, c.current_start, c.pos);
            }
        },
        '{' => {
            c.skipChar();
            try c.compilePortamento(part);
        },
        '*' => {
            c.skipChar();
            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (c.takeComma()) {
                const new_state = try c.takeEnum(enum { on, off }) orelse return c.report(.expected_param);
                try c.addSetLfoEnabledCommand(part, .user(lfo), new_state == .on);
            } else {
                try part.addCommand(c, .toggle_lfo, .{ .lfo = .user(lfo) });
            }
        },
        'M' => {
            c.skipChar();
            try c.compileLfoCommand(part);
        },
        '_' => {
            c.skipChar();
            switch (c.peekChar()) {
                '{' => {
                    c.skipChar();
                    try c.compileKeyChange(part);
                },
                else => {
                    c.skipChar();
                    try c.reportSpan(.invalid_command, c.current_start, c.pos);
                },
            }
        },
        else => {
            c.skipChar();
            try c.reportSpan(.invalid_command, c.current_start, c.pos);
        },
    }
}

fn compilePortamento(c: *Compiler, part: *Part) !void {
    var from: f32 = 0.0;
    var to: f32 = 0.0;
    var state: enum { start, after_from, after_to } = .start;
    while (true) switch (c.peekChar()) {
        '>' => {
            c.skipChar();
            part.octave += 1.0;
        },
        '<' => {
            c.skipChar();
            part.octave -= 1.0;
        },
        '}' => {
            if (state != .after_to) try c.report(.expected_note);
            c.skipChar();
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
                try c.skipUnexpectedCharacter();
            },
        },
        else => {
            try c.skipUnexpectedCharacter();
        },
    };
    const length = try c.takeNoteLength(part);

    try c.addSetLfoTargetCommand(part, .porta, .freq);
    try c.addSetLfoSizeCommand(part, .porta, .{ .scale = from, .offset = -from });
    try c.addSetLfoWaveCommand(part, .porta, .{ .exp = .{
        .mul = (@log2(to) - @log2(from)) / @as(f32, @floatFromInt(@backingInt(length))),
    } });
    try part.addCommand(c, .toggle_lfo, .{ .lfo = .porta });
    try part.addCommand(c, .key_on, .{ .freq = from });
    try part.addCommand(c, .rest, .{ .ticks = length });
    try part.addCommand(c, .toggle_lfo, .{ .lfo = .porta });
    try part.addCommand(c, .key_on, .{ .freq = to });
    try part.addCommand(c, .key_off, .{ .none = {} });
}

fn compileLfoCommand(c: *Compiler, part: *Part) !void {
    switch (c.peekChar()) {
        'T' => {
            c.skipChar();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const target = try c.takeEnum(Lfo.Target) orelse return c.report(.expected_param);

            try c.addSetLfoTargetCommand(part, .user(lfo), target);
        },
        'S' => {
            c.skipChar();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const scale = try c.takeNumber(f32) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const offset = try c.takeNumber(f32) orelse return c.report(.expected_param);

            try c.addSetLfoSizeCommand(part, .user(lfo), .{ .scale = scale, .offset = offset });
        },
        'W' => {
            c.skipChar();

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
            c.skipChar();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const trigger = try c.takeEnum(Lfo.Trigger) orelse return c.report(.expected_param);

            try c.addSetLfoTriggerCommand(part, .user(lfo), trigger);
        },
        'A' => {
            c.skipChar();

            const lfo = try c.takeNumber(Lfo.Index.User) orelse return c.report(.expected_param);
            if (!c.takeComma()) return c.report(.expected_param);
            const adjust = try c.takeEnum(enum { on, off }) orelse return c.report(.expected_param);

            try c.addSetLfoAdjustCommand(part, .user(lfo), adjust == .on);
        },
        else => {
            c.skipChar();
            try c.reportSpan(.invalid_command, c.current_start, c.pos);
        },
    }
}

fn compileKeyChange(c: *Compiler, part: *Part) !void {
    while (true) switch (c.peekChar()) {
        '+', '-', '=' => {
            const accidentals = c.takeAccidentals().?;
            while (c.takeNoteName()) |note| part.default_accidentals.set(note, accidentals);
        },
        '}' => {
            c.skipChar();
            break;
        },
        else => {
            try c.skipUnexpectedCharacter();
        },
    };
}

fn addSetLfoEnabledCommand(c: *Compiler, part: *Part, index: Lfo.Index, enabled: bool) !void {
    try part.addCommand(c, .set_lfo_enabled, .{ .lfo_enabled = .{
        .index = index,
        .enabled = enabled,
    } });
}

fn addSetLfoTargetCommand(c: *Compiler, part: *Part, index: Lfo.Index, target: Lfo.Target) !void {
    try part.addCommand(c, .set_lfo_target, .{ .lfo_target = .{
        .index = index,
        .target = target,
    } });
}

fn addSetLfoSizeCommand(c: *Compiler, part: *Part, index: Lfo.Index, size: Lfo.Size) !void {
    const data = c.extra.currentIndex();
    try c.extra.encode(c.gpa, size);
    try part.addCommand(c, .set_lfo_size, .{ .lfo_data = .{
        .index = index,
        .data = data,
    } });
}

fn addSetLfoWaveCommand(c: *Compiler, part: *Part, index: Lfo.Index, wave: Lfo.Wave) !void {
    const data = c.extra.currentIndex();
    try c.extra.encode(c.gpa, wave);
    try part.addCommand(c, .set_lfo_wave, .{ .lfo_data = .{
        .index = index,
        .data = data,
    } });
}

fn addSetLfoTriggerCommand(c: *Compiler, part: *Part, index: Lfo.Index, trigger: Lfo.Trigger) !void {
    try part.addCommand(c, .set_lfo_trigger, .{ .lfo_trigger = .{
        .index = index,
        .trigger = trigger,
    } });
}

fn addSetLfoAdjustCommand(c: *Compiler, part: *Part, index: Lfo.Index, adjust: bool) !void {
    try part.addCommand(c, .set_lfo_adjust, .{ .lfo_adjust = .{
        .index = index,
        .adjust = adjust,
    } });
}

fn sourceChar(c: *const Compiler, index: SourceIndex) u21 {
    const pos = @backingInt(index);
    const b = c.source[pos];
    return switch (std.unicode.utf8ByteSequenceLength(b) catch unreachable) {
        1 => b,
        2 => std.unicode.utf8Decode2(c.source[pos..][0..2].*) catch unreachable,
        3 => std.unicode.utf8Decode3(c.source[pos..][0..3].*) catch unreachable,
        4 => std.unicode.utf8Decode4(c.source[pos..][0..4].*) catch unreachable,
        else => unreachable,
    };
}

fn sourceSlice(c: *const Compiler, start: SourceIndex, end: SourceIndex) []const u8 {
    return c.source[@backingInt(start)..@backingInt(end)];
}

fn peekChar(c: *const Compiler) u21 {
    return c.sourceChar(c.pos);
}

fn skipChar(c: *Compiler) void {
    if (@backingInt(c.pos) < c.source.len) {
        const b = c.source[@backingInt(c.pos)];
        c.pos = c.pos.plusBytes(std.unicode.utf8ByteSequenceLength(b) catch unreachable);
    }
}

fn expectChar(c: *Compiler, ch: u8) !void {
    if (c.peekChar() != ch) {
        try c.reportData(.expected_char, .{ .char = ch });
        return;
    }
    c.skipChar();
}

fn expectSpace(c: *Compiler) !void {
    switch (c.peekChar()) {
        ' ', '\t' => c.skipChar(),
        '\r', '\n' => {},
        else => try c.report(.expected_space),
    }
}

fn skipLine(c: *Compiler) void {
    var eol = std.mem.findAnyPos(u8, c.source, @backingInt(c.pos), "\r\n") orelse {
        c.pos = @fromBackingInt(@intCast(c.source.len));
        return;
    };
    if (c.source[eol] == '\r' and c.source[eol + 1] == '\n') eol += 1;
    c.pos = @fromBackingInt(@intCast(eol + 1));
}

fn skipLineAndContinuation(c: *Compiler) void {
    while (c.continueLine()) {
        c.skipLine();
        // After skipping the line, if the character we're looking at isn't a
        // space (or comment), it means we've exhausted the continuation.
        switch (c.peekChar()) {
            ' ', '\t', '\r', '\n', ';' => {},
            else => return,
        }
    }
}

fn continueLine(c: *Compiler) bool {
    var indented = true;
    while (true) switch (c.peekChar()) {
        eof => return false,
        ';' => {
            c.skipLine();
            indented = false;
        },
        ' ', '\t' => {
            c.skipChar();
            indented = true;
        },
        '\r', '\n' => {
            c.skipChar();
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
        try c.skipUnexpectedCharacter();
        c.skipLineAndContinuation();
    }
}

fn takeComma(c: *Compiler) bool {
    if (c.peekChar() == ',') {
        c.skipChar();
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
        switch (c.peekChar()) {
            ' ', '\t', '\r', '\n' => {}, // continuation line
            else => break,
        }
    }
    return try c.strings.finishWriting(c.gpa, start);
}

fn skipMatching(c: *Compiler, pred: fn (u21) bool) void {
    while (pred(c.peekChar())) c.skipChar();
}

fn isNameChar(ch: u21) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
        else => false,
    };
}

fn takeName(c: *Compiler) ?[]const u8 {
    const start = c.pos;
    c.skipMatching(isNameChar);
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

fn isUnsignedIntChar(ch: u21) bool {
    return switch (ch) {
        '0'...'9' => true,
        else => false,
    };
}

fn isSignedIntChar(ch: u21) bool {
    return switch (ch) {
        '+', '-', '0'...'9' => true,
        else => false,
    };
}

fn isFloatChar(ch: u21) bool {
    return switch (ch) {
        '+', '-', '0'...'9', '.' => true,
        else => false,
    };
}

fn takeNoteLength(c: *Compiler, part: *const Part) !Ticks {
    const Op = enum {
        plus,
        minus,

        fn apply(op: @This(), v1: Ticks, v2: Ticks) Ticks {
            return switch (op) {
                .plus => v1.plus(v2),
                .minus => v1.minus(v2),
            };
        }
    };

    var total_len: Ticks = .zero;
    var curr_op: Op = .plus;
    var curr_start = c.pos;
    var curr_len = try c.takeNoteLengthValue() orelse part.default_length;
    while (true) switch (c.peekChar()) {
        '.' => {
            c.skipChar();
            curr_len = curr_len.dot() catch {
                try c.reportSpan(.last_command_not_note, curr_start, c.pos);
                continue;
            };
        },
        '+', '-' => |op| {
            c.skipChar();
            total_len = curr_op.apply(total_len, curr_len);
            curr_op = switch (op) {
                '+' => .plus,
                '-' => .minus,
                else => unreachable,
            };
            curr_start = c.pos;
            curr_len = try c.takeNoteLengthValue() orelse none: {
                // It is mandatory to specify a length explicitly after +/-.
                try c.report(.expected_param);
                break :none part.default_length;
            };
        },
        else => break,
    };
    return curr_op.apply(total_len, curr_len);
}

fn takeNoteLengthValue(c: *Compiler) !?Ticks {
    const start = c.pos;
    if (c.peekChar() == '%') {
        c.skipChar();
        return try c.takeNumber(Ticks) orelse {
            try c.report(.expected_param);
            return null;
        };
    } else {
        const divisor = try c.takeNumber(u32) orelse return null;
        return Ticks.zenlen.fraction(divisor) catch {
            try c.reportPos(.indivisible_note_length, start);
            return null;
        };
    }
}

fn takeNumber(c: *Compiler, T: type) !?T {
    const start = c.pos;
    switch (@typeInfo(T)) {
        .@"enum" => |@"enum"| {
            return @fromBackingInt(try c.takeNumber(@"enum".tag_type) orelse return null);
        },
        .@"struct" => |@"struct"| {
            comptime assert(@"struct".field_names.len == 1);
            var s: T = undefined;
            @field(s, @"struct".field_names[0]) = try c.takeNumber(@"struct".field_types[0]) orelse return null;
            return s;
        },
        .int => |int| switch (int.signedness) {
            .unsigned => {
                c.skipMatching(isUnsignedIntChar);
                if (c.pos == start) return null;
                return std.fmt.parseUnsigned(T, c.sourceSlice(start, c.pos), 10) catch {
                    try c.reportDataPos(.invalid_int, .{ .int = int }, start);
                    return null;
                };
            },
            .signed => {
                c.skipMatching(isSignedIntChar);
                if (c.pos == start) return null;
                return std.fmt.parseInt(T, c.sourceSlice(start, c.pos), 10) catch {
                    try c.reportDataPos(.invalid_int, .{ .int = int }, start);
                    return null;
                };
            },
        },
        .float => {
            c.skipMatching(isFloatChar);
            if (c.pos == start) return null;
            return std.fmt.parseFloat(T, c.sourceSlice(start, c.pos)) catch {
                try c.reportPos(.invalid_float, start);
                return null;
            };
        },
        else => comptime unreachable,
    }
}

fn isPartNameChar(ch: u21) bool {
    return switch (ch) {
        'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

fn takePartNames(c: *Compiler) ![]const u8 {
    const start = c.pos;
    while (true) {
        c.skipMatching(isPartNameChar);
        switch (c.peekChar()) {
            eof, ' ', '\t', '\r', '\n' => break,
            else => {
                const part_start = c.pos;
                c.skipChar();
                try c.reportSpan(.invalid_part_name, part_start, c.pos);
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
    const note: Note = switch (c.peekChar()) {
        'c' => .c,
        'd' => .d,
        'e' => .e,
        'f' => .f,
        'g' => .g,
        'a' => .a,
        'b' => .b,
        else => return null,
    };
    c.skipChar();
    return note;
}

fn takeAccidentals(c: *Compiler) ?f32 {
    var res: ?f32 = null;
    while (true) switch (c.peekChar()) {
        '=' => {
            res = 0.0;
            c.skipChar();
        },
        '+' => {
            res = (res orelse 0.0) + 1.0;
            c.skipChar();
        },
        '-' => {
            res = (res orelse 0.0) - 1.0;
            c.skipChar();
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

fn skipUnexpectedCharacter(c: *Compiler) !void {
    const start = c.pos;
    c.skipChar();
    try c.reportSpan(.unexpected_character, start, c.pos);
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
        return @fromBackingInt(@intCast(part.commands.len));
    }

    fn addCommand(part: *Part, c: *const Compiler, tag: Command.Tag, data: Command.Data) !void {
        try part.commands.append(c.gpa, .{
            .tag = tag,
            .data = data,
            .span = .{ .start = c.current_start, .end = c.pos },
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
        char: u21,
        int: std.lang.Type.Int,
    };

    pub fn format(err: Error, w: *Writer) Writer.Error!void {
        switch (err.tag) {
            .unexpected_character => try w.print("unexpected character", .{}),
            .unexpected_end_of_patch => try w.print("unexpected end of patch", .{}),
            .expected_name => try w.print("expected name", .{}),
            .expected_param => try w.print("expected parameter", .{}),
            .expected_note => try w.print("expected note", .{}),
            .expected_char => try w.print("expected '{u}'", .{err.data.char}),
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
