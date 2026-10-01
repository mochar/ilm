const std = @import("std");
const Allocator = std.mem.Allocator;
pub const sqlite = @import("sqlite");
pub const Diagnostics = sqlite.Diagnostics;

pub fn queryAll(comptime T: type, alloc: Allocator, stmt: anytype, values: anytype) ![]T {
    var diags: sqlite.Diagnostics = .{};
    var iter = try stmt.iteratorAlloc(T, alloc, values);
    var rows: std.ArrayList(T) = .empty;
    defer rows.deinit(alloc);
    while (try iter.nextAlloc(alloc, .{ .diags = &diags })) |row| {
        try rows.append(alloc, row);
    }
    return try rows.toOwnedSlice(alloc);
}
