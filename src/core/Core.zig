const std = @import("std");
const database = @import("database.zig");
const Id = database.Id;
const sqlite = @import("sqlite");

const Core = @This();

gpa: std.mem.Allocator,
io: std.Io,
db: sqlite.Db,

pub const Options = struct {
    sqlite_diagnostics: ?*sqlite.Diagnostics = null,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, data_dir: []const u8, options: Options) !*Core {
    const db_path = try std.fs.path.joinZ(gpa, &.{ data_dir, "ilm.db" });
    defer gpa.free(db_path);

    const db = try database.getDb(.{ .path = db_path, .diags = options.sqlite_diagnostics });

    // Create instance and return
    const core = try gpa.create(Core);
    core.* = .{
        .gpa = gpa,
        .io = io,
        .db = db,
    };
    return core;
}

pub fn deinit(core: *Core) void {
    core.db.deinit();
    core.gpa.destroy(core);
}

/// Returns true if still functional
pub fn isValid(core: *Core) bool {
    return database.isValid(&core.db);
}

pub fn newId(core: *Core) Id {
    return Id.new(core.io);
}
