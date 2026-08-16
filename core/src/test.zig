test "simple C major scale" {
    try runTest("c-major");
}

test "complex notes" {
    try runTest("complex-notes");
}

test "directives" {
    try runTest("directives");
}

test "macros" {
    try runTest("macros");
}

test "octave changes" {
    try runTest("octaves");
}

test "rests and ties" {
    try runTest("rests-ties");
}

test "volume tempo and pan" {
    try runTest("params");
}

test "loops" {
    try runTest("loops");
}

test "patches" {
    try runTest("patches");
}

test "lfo" {
    try runTest("lfo");
}

test "portamento" {
    try runTest("portamento");
}

test "key change" {
    try runTest("key-change");
}

test "multiple parts" {
    try runTest("multiple-parts");
}

test "skip" {
    try runTest("skip");
}

fn runTest(comptime name: []const u8) !void {
    const gpa = std.testing.allocator;

    const source = @embedFile("./testdata/" ++ name ++ ".zfm");

    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();
    try std.testing.expect(compiler.errors.items.len == 0);
    var mod: Module = try compiler.toModule();
    defer mod.deinit(gpa);

    // JSON output snapshot
    const expected_json = @embedFile("./testdata/" ++ name ++ ".json");
    var actual_json: Writer.Allocating = .init(gpa);
    defer actual_json.deinit();
    try mod.dumpJson(&actual_json.writer);
    try std.testing.expectEqualStrings(expected_json, actual_json.written());

    // Module dump/load round-trip
    var dumped: Writer.Allocating = .init(gpa);
    defer dumped.deinit();
    try mod.dump(gpa, &dumped.writer);
    var dumped_reader: Reader = .fixed(dumped.written());
    var loaded_mod: Module = try .load(gpa, &dumped_reader);
    defer loaded_mod.deinit(gpa);
    try expectEqualModules(&mod, &loaded_mod);

    // Driver log
    var actual_log: Writer.Allocating = .init(gpa);
    defer actual_log.deinit();

    const voices = try gpa.alloc(Synth.Voice, mod.parts.len);
    defer gpa.free(voices);
    const slots = try gpa.alloc(Synth.Slot, mod.parts.len * Synth.Voice.n_slots);
    defer gpa.free(slots);
    var synth: Synth = .init(voices, slots, Synth.default_volume);
    const parts = try gpa.alloc(Driver.Part, mod.parts.len);
    defer gpa.free(parts);
    var driver: Driver = .init(&synth, &mod, parts);
    var logging_hooks: Driver.LoggingHooks = .init(&actual_log.writer);
    driver.hooks = logging_hooks.hooks();

    while (true) {
        _ = driver.sample();
        const ended = for (driver.parts) |part| {
            if (!part.ended and part.cycle == 0) break false;
        } else true;
        if (ended) break;
    }

    const expected_log = @embedFile("./testdata/" ++ name ++ ".log.jsonl");
    try std.testing.expectEqualStrings(expected_log, actual_log.written());
}

fn expectEqualModules(expected: *const Module, actual: *const Module) !void {
    try std.testing.expectEqualSlices(Command.Tag, expected.commands.items(.tag), actual.commands.items(.tag));
    // We already know at this point that the tags are the same, thanks to the previous assertion.
    for (
        expected.commands.items(.tag),
        expected.commands.items(.data),
        actual.commands.items(.data),
    ) |tag, expected_data, actual_data| {
        switch (tag) {
            inline else => |t| {
                const data_tag = @tagName(Command.Tag.data_tags[@backingInt(t)]);
                try std.testing.expectEqual(
                    @field(expected_data, data_tag),
                    @field(actual_data, data_tag),
                );
            },
        }
    }
    try std.testing.expectEqualSlices(SourceIndex.Span, expected.commands.items(.span), actual.commands.items(.span));
    try std.testing.expectEqualSlices(bool, expected.commands.items(.skipped), actual.commands.items(.skipped));
    try std.testing.expectEqualSlices(Module.Part, expected.parts, actual.parts);
    try std.testing.expectEqualSlices(Patch.Entry, expected.patches, actual.patches);
    try std.testing.expectEqualSlices(Extra.Datum, expected.extra.data, actual.extra.data);
    try std.testing.expectEqualStrings(expected.strings.bytes, actual.strings.bytes);

    try std.testing.expectEqual(expected.title, actual.title);
    try std.testing.expectEqual(expected.composer, actual.composer);
    try std.testing.expectEqual(expected.arranger, actual.arranger);
    try std.testing.expectEqual(expected.initial_tempo.bpm, actual.initial_tempo.bpm);
}

test "invalid note lengths" {
    try runErrorTest("invalid-note-lengths");
}

test "invalid patches" {
    try runErrorTest("invalid-patches");
}

test "invalid directives" {
    try runErrorTest("invalid-directives");
}

test "invalid commands" {
    try runErrorTest("invalid-commands");
}

test "invalid part names" {
    try runErrorTest("invalid-part-names");
}

test "invalid portamento" {
    try runErrorTest("invalid-portamento");
}

test "loop errors" {
    try runErrorTest("loop-errors");
}

test "undefined symbols" {
    try runErrorTest("undefined-symbols");
}

test "macro depth" {
    try runErrorTest("macro-depth");
}

test "tie errors" {
    try runErrorTest("tie-errors");
}

test "invalid skip" {
    try runErrorTest("invalid-skip");
}

fn runErrorTest(comptime name: []const u8) !void {
    const gpa = std.testing.allocator;

    const source = @embedFile("./testdata/errors/" ++ name ++ ".zfm");
    const expected_errors = @embedFile("./testdata/errors/" ++ name ++ ".err");

    var compiler: Compiler = .init(gpa, source);
    defer compiler.deinit();
    try compiler.compile();
    var actual_errors: Writer.Allocating = .init(gpa);
    defer actual_errors.deinit();
    for (compiler.errors.items) |err| {
        const loc = compiler.sourceLocation(err.span);
        if (err.part) |part| {
            try actual_errors.writer.print("{}:{}-{}:{}: part {c}: {f}\n", .{ loc.start.line, loc.start.column, loc.end.line, loc.end.column, part, err });
        } else {
            try actual_errors.writer.print("{}:{}-{}:{}: {f}\n", .{ loc.start.line, loc.start.column, loc.end.line, loc.end.column, err });
        }
    }

    try std.testing.expectEqualStrings(expected_errors, actual_errors.written());
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const zfm = @import("./zfm.zig");
const Frame = zfm.Frame;
const Compiler = zfm.Compiler;
const Module = zfm.Module;
const Command = Module.Command;
const SourceIndex = Module.SourceIndex;
const Patch = Module.Patch;
const Extra = Module.Extra;
const Synth = zfm.Synth;
const Driver = zfm.Driver;
