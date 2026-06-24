bytes: std.ArrayList(u8),
lookup: std.HashMapUnmanaged(Index, void, Context, std.hash_map.default_max_load_percentage),

pub const empty: StringPool = .{ .bytes = .empty, .lookup = .empty };

pub const Index = enum(u32) {
    empty = 0,
    _,
};

pub const PendingIndex = enum(u32) { _ };

pub fn deinit(sp: *StringPool, gpa: Allocator) void {
    sp.bytes.deinit(gpa);
    sp.lookup.deinit(gpa);
    sp.* = undefined;
}

pub fn toOwnedSlice(sp: *StringPool, gpa: Allocator) Allocator.Error!Slice {
    const bytes = try sp.bytes.toOwnedSlice(gpa);
    errdefer comptime unreachable;
    sp.lookup.clearAndFree(gpa);
    return .{ .bytes = bytes };
}

pub fn string(sp: *const StringPool, s: Index) []const u8 {
    return std.mem.sliceTo(sp.bytes.items[@intFromEnum(s)..], 0);
}

pub fn find(sp: *const StringPool, s: []const u8) ?Index {
    return sp.lookup.getKeyAdapted(s, Adapter{ .bytes = &sp.bytes });
}

pub fn intern(sp: *StringPool, gpa: Allocator, s: []const u8) Allocator.Error!Index {
    const gop = try sp.lookup.getOrPutContextAdapted(gpa, s, Adapter{ .bytes = &sp.bytes }, .{ .bytes = &sp.bytes });
    if (gop.found_existing) return gop.key_ptr.*;
    errdefer sp.lookup.removeByPtr(gop.key_ptr);
    const index: Index = @enumFromInt(sp.bytes.items.len + 1);
    gop.key_ptr.* = index;
    try sp.bytes.ensureUnusedCapacity(gpa, s.len + 1);
    sp.bytes.appendAssumeCapacity(0);
    sp.bytes.appendSliceAssumeCapacity(s);
    return index;
}

pub fn writingIndex(sp: *const StringPool) PendingIndex {
    return @enumFromInt(sp.bytes.items.len);
}

pub fn startWriting(sp: *StringPool, gpa: Allocator) Allocator.Error!PendingIndex {
    try sp.bytes.append(gpa, 0);
    return sp.writingIndex();
}

pub fn finishWriting(sp: *StringPool, gpa: Allocator, start: PendingIndex) Allocator.Error!Index {
    const s = std.mem.sliceTo(sp.bytes.items[@intFromEnum(start)..], 0);
    const gop = try sp.lookup.getOrPutContextAdapted(gpa, s, Adapter{ .bytes = &sp.bytes }, .{ .bytes = &sp.bytes });
    if (gop.found_existing) {
        // Same string already found in the pool; use that one.
        sp.bytes.shrinkRetainingCapacity(@intFromEnum(start) - 1);
        return gop.key_ptr.*;
    }
    gop.key_ptr.* = @enumFromInt(@intFromEnum(start));
    return gop.key_ptr.*;
}

pub const Slice = struct {
    bytes: []u8,

    pub const empty: Slice = .{ .bytes = &.{} };

    pub fn deinit(ss: *Slice, gpa: Allocator) void {
        gpa.free(ss.bytes);
        ss.* = undefined;
    }

    pub fn string(ss: *const Slice, s: Index) []const u8 {
        return std.mem.sliceTo(ss.bytes[@intFromEnum(s)..], 0);
    }
};

// Adapted from std.hash_map.StringIndexContext
const Context = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(ctx: @This(), a: Index, b: Index) bool {
        _ = ctx;
        return a == b;
    }

    pub fn hash(ctx: @This(), key: Index) u64 {
        return std.hash_map.hashString(std.mem.sliceTo(ctx.bytes.items[@intFromEnum(key)..], 0));
    }
};

// Adapted from std.hash_map.StringIndexAdapter
const Adapter = struct {
    bytes: *const std.ArrayList(u8),

    pub fn eql(ctx: @This(), a: []const u8, b: Index) bool {
        return std.mem.eql(u8, a, std.mem.sliceTo(ctx.bytes.items[@intFromEnum(b)..], 0));
    }

    pub fn hash(ctx: @This(), adapted_key: []const u8) u64 {
        _ = ctx;
        assert(std.mem.findScalar(u8, adapted_key, 0) == null);
        return std.hash_map.hashString(adapted_key);
    }
};

const StringPool = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
