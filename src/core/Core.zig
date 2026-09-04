const std = @import("std");
const Core = @This();

counter: i64 = 0,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !*Core {
    const core = try allocator.create(Core);
    core.* = .{
        .counter = 0,
        .allocator = allocator,
    };
    return core;
}

pub fn deinit(core: *Core) void {
    core.allocator.destroy(core);
}

pub fn increment(core: *Core) i64 {
    core.counter += 1;
    return core.counter;
}
