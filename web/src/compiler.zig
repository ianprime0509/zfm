const gpa = std.heap.wasm_allocator;

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
    mod.deinit(gpa);
    mod = .empty;

    try transfer.append(gpa, 0);
    var compiler: Compiler = .init(gpa, transfer.items[0 .. transfer.items.len - 1 :0]);
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

        try out.endObject();
    }
    try out.endArray();
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
const Patch = Module.Patch;
const Synth = zfm.Synth;
const Voice = Synth.Voice;
