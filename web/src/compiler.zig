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
    consoleLog(@intFromEnum(level), msg.ptr, msg.len);
}

const gpa = std.heap.wasm_allocator;

var transfer_buf: std.ArrayList(u8) = .empty;

export fn transferBufPtr() [*]u8 {
    return transfer_buf.items.ptr;
}

export fn transferBufReserve(n: usize) void {
    transfer_buf.ensureTotalCapacity(gpa, n) catch @panic("OOM");
    transfer_buf.items.len = n;
}

export fn compilePatch() usize {
    return compilePatchInner() catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
        error.CompileFailed => 0,
    };
}

fn compilePatchInner() !usize {
    try transfer_buf.append(gpa, 0);
    var compiler: Compiler = .init(gpa, transfer_buf.items[0 .. transfer_buf.items.len - 1 :0]);
    defer compiler.deinit();
    try compiler.compile();
    if (compiler.errors.items.len > 0) return error.CompileFailed;
    var mod = try compiler.toModule();
    defer mod.deinit(gpa);
    // TODO: this is not really enough to guarantee it's only a single patch and nothing else
    if (mod.patches.count() != 1 or mod.parts.len != 0) return error.CompileFailed;
    transfer_buf.clearRetainingCapacity();

    var w: std.Io.Writer.Allocating = .fromArrayList(gpa, &transfer_buf);
    var json: std.json.Stringify = .{ .writer = &w.writer };
    const patch_index = mod.patches.values()[0];
    const patch, _ = mod.extra.decode(Patch, patch_index);
    patchToJson(&json, patch) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
    transfer_buf = w.toArrayList();
    return transfer_buf.items.len;
}

fn patchToJson(json: *std.json.Stringify, patch: Patch) !void {
    try json.beginObject();
    try json.objectField("connections");
    try json.beginArray();
    for (patch.connections.deps, 0..) |slot_deps, to| {
        var iter = slot_deps.iterator(.{});
        while (iter.next()) |from| {
            try json.write(.{ from, to });
        }
    }
    try json.endArray();
    try json.objectField("slots");
    try json.beginArray();
    for (patch.slot_params, patch.slot_env_params) |slot_params, slot_env_params| {
        try json.beginObject();
        // Note: json.print is needed here because json.write will internally
        // convert f32 to f64, resulting in imprecision (e.g. 0.7 -> 0.699999988079071)
        inline for (@typeInfo(Slot.Params).@"struct".field_names) |field| {
            try json.objectField(field);
            try json.print("{}", .{@field(slot_params, field)});
        }
        inline for (@typeInfo(Envelope.Params).@"struct".field_names) |field| {
            try json.objectField(field);
            try json.print("{}", .{@field(slot_env_params, field)});
        }
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const zfm = @import("zfm");
const Compiler = zfm.Compiler;
const Module = zfm.Module;
const Patch = Module.Patch;
const Synth = zfm.Synth;
const Slot = Synth.Slot;
const Envelope = Synth.Envelope;
