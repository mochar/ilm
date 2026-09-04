const std = @import("std");
const sqlite = @import("sqlite");
const Core = @This();

counter: i64 = 0,
allocator: std.mem.Allocator,
db: sqlite.Db,

pub fn init(allocator: std.mem.Allocator, data_dir: []const u8) !*Core {
    const db_path = try std.fs.path.joinZ(allocator, &.{ data_dir, "ilm.db" });
    defer allocator.free(db_path);

    const db = try sqlite.Db.init(.{
        .mode = .{ .File = db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });

    const core = try allocator.create(Core);
    core.* = .{
        .counter = 0,
        .allocator = allocator,
        .db = db,
    };
    return core;
}

pub fn deinit(core: *Core) void {
    core.db.deinit();
    core.allocator.destroy(core);
}

pub fn increment(core: *Core) i64 {
    core.counter += 1;
    return core.counter;
}
